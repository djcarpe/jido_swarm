defmodule JidoSwarm.Hive.Feed do
  @moduledoc """
  What the mesh is doing, as it happens.

  The shared graph changes without this node being involved — another pod's
  agent writes an insight and it arrives here as a delta, applied by
  `Jido.Context.Graph` in its own process. Until now nothing in the app
  watched that traffic; the console re-read the board on a timer and could not
  say where anything came from. This process is the one subscriber to the
  mesh, and it keeps the picture the console needs:

  * a ring of the most recent deltas, each summarised in the Hive's words and
    marked local or remote;
  * per-origin counters — deltas, operations, nodes and edges written, the
    highest sequence seen, when it was last heard from, and how far behind its
    writes arrive;
  * its own identity, so the other pods can be asked what they have seen and
    the operator can watch the replicas converge.

  Each delta is rebroadcast on the `"hive"` PubSub topic as
  `{:hive_delta, entry}`, so a LiveView updates the moment the graph does
  rather than when the timer fires.

  ## Why one subscriber and no graph reads

  The router sends every matching delta to every subscriber, so ten LiveViews
  subscribing directly would be ten copies of the traffic and ten places to
  keep counters. One process keeps them once and fans out summaries. It never
  reads the graph while handling a delta: everything it records comes from the
  delta itself, so a burst of replication cannot queue graph work behind it.

  ## Why lag is approximate

  Lag is the delta's own timestamp against this node's clock at receipt, so it
  includes whatever the two pods' clocks disagree by. In a cluster with NTP
  that is milliseconds; without it the number is still useful as a trend and
  useless as a measurement, which is why the console labels it as such.
  """

  use GenServer

  require Logger

  alias Jido.Context.Delta
  alias Jido.Context.Mesh
  alias JidoSwarm.Hive.Canvas

  @default_topics ["hive.**", "knowledge.**", "context.**"]
  @default_ring 200
  @lag_samples 64

  # More deltas than this inside one window is a replay, not activity — the S3
  # log catching up, a pod restoring. The console is told once and re-reads,
  # instead of animating a thousand arrivals.
  @burst_window_ms 100
  @burst_limit 50

  @type entry :: %{
          id: String.t(),
          origin: String.t(),
          local: boolean(),
          topic: String.t(),
          seq: non_neg_integer(),
          ts: integer(),
          at: integer(),
          lag_ms: non_neg_integer() | nil,
          ops: non_neg_integer(),
          summary: String.t(),
          kinds: [String.t()]
        }

  # ===========================================================================
  # Lifecycle
  # ===========================================================================

  @doc """
  Starts the feed.

  Options: `:name` (default this module), `:graph` and `:mesh` (default the
  swarm's), `:pubsub_topic` (default `"hive"`), `:topics` to subscribe to
  (default the Hive, knowledge and chat topics), `:ring` (how many recent
  deltas to keep, default #{@default_ring}).
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    graph = Keyword.get(opts, :graph, JidoSwarm.graph())
    mesh = Keyword.get(opts, :mesh, JidoSwarm.mesh())
    :ok = Mesh.subscribe(mesh, Keyword.get(opts, :topics, @default_topics))

    {:ok,
     %{
       graph: graph,
       mesh: mesh,
       origin: Jido.Context.Graph.origin(graph),
       node: node(),
       since: now(),
       pubsub_topic: Keyword.get(opts, :pubsub_topic, "hive"),
       ring_size: Keyword.get(opts, :ring, @default_ring),
       ring: [],
       origins: %{},
       burst: {0, 0}
     }}
  end

  # ===========================================================================
  # Reading
  # ===========================================================================

  @doc "This replica: its origin, BEAM node and when the feed started."
  @spec me(GenServer.server()) :: %{origin: String.t(), node: node(), since: integer()}
  def me(server \\ __MODULE__), do: GenServer.call(server, :me)

  @doc "The most recent deltas, newest first."
  @spec recent(GenServer.server(), pos_integer()) :: [entry()]
  def recent(server \\ __MODULE__, limit), do: GenServer.call(server, {:recent, limit})

  @doc """
  What has been heard from each origin, this replica first.

  Lag fields are `nil` for the local origin — its writes do not travel.
  """
  @spec origins(GenServer.server()) :: [map()]
  def origins(server \\ __MODULE__), do: GenServer.call(server, :origins)

  @doc """
  What this replica has seen, for another replica asking over `:erpc`: its
  origin, node, and the highest sequence it holds from every origin.
  """
  @spec identity(GenServer.server()) :: %{origin: String.t(), node: node(), seen: map()}
  def identity(server \\ __MODULE__), do: GenServer.call(server, :identity)

  @doc """
  Every replica in the cluster and what each has seen, this one first.

  Asks each connected node's feed for its identity, with a short timeout: a
  partitioned node reads as `:unreachable` rather than stalling the caller.
  Rows are `%{node, origin, local?, connected?, seen}`.
  """
  @spec peers(GenServer.server(), timeout()) :: [map()]
  def peers(server \\ __MODULE__, timeout \\ 1_000) do
    mine = identity(server)
    name = if is_atom(server), do: server, else: __MODULE__
    nodes = Node.list()

    remote =
      nodes
      |> :erpc.multicall(__MODULE__, :identity, [name], timeout)
      |> Enum.zip(nodes)
      |> Enum.map(fn
        {{:ok, %{origin: origin, seen: seen}}, node} ->
          %{node: node, origin: origin, local?: false, connected?: true, seen: seen}

        {_, node} ->
          %{node: node, origin: nil, local?: false, connected?: false, seen: :unreachable}
      end)

    [
      %{node: mine.node, origin: mine.origin, local?: true, connected?: true, seen: mine.seen}
      | remote
    ]
  end

  @doc "Forgets the ring and the counters. For tests and the console's reset."
  @spec reset(GenServer.server()) :: :ok
  def reset(server \\ __MODULE__), do: GenServer.call(server, :reset)

  # ===========================================================================
  # Server
  # ===========================================================================

  @impl true
  def handle_call(:me, _from, state) do
    {:reply, %{origin: state.origin, node: state.node, since: state.since}, state}
  end

  def handle_call({:recent, limit}, _from, state) do
    {:reply, Enum.take(state.ring, limit), state}
  end

  def handle_call(:origins, _from, state) do
    now = now()

    rows =
      state.origins
      |> Enum.map(fn {origin, stats} -> origin_row(origin, stats, state.origin, now) end)
      |> Enum.sort_by(&{not &1.local?, &1.origin})

    {:reply, rows, state}
  end

  def handle_call(:identity, _from, state) do
    seen = Map.new(state.origins, fn {origin, stats} -> {origin, stats.last_seq} end)
    {:reply, %{origin: state.origin, node: state.node, seen: seen}, state}
  end

  def handle_call(:reset, _from, state) do
    {:reply, :ok, %{state | ring: [], origins: %{}, burst: {0, 0}}}
  end

  @impl true
  def handle_info({:jido_context_delta, _mesh, %Delta{} = delta}, state) do
    now = now()
    entry = entry(delta, state.origin, now)

    # The ring keeps the summary; the broadcast also carries what the canvas
    # should draw, which is only ever needed once, right now.
    state =
      state
      |> record(delta, entry, now)
      |> announce(Map.put(entry, :draw, Canvas.delta_ops(delta)), now)

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ===========================================================================
  # Recording
  # ===========================================================================

  defp entry(%Delta{} = delta, me, now) do
    local = delta.origin == me

    %{
      id: delta.id,
      origin: delta.origin,
      local: local,
      topic: delta.topic,
      seq: delta.seq,
      ts: delta.ts,
      at: now,
      lag_ms: if(local, do: nil, else: max(now - delta.ts, 0)),
      ops: length(delta.ops),
      summary: Canvas.summarize(delta),
      kinds: kinds(delta)
    }
  end

  defp kinds(%Delta{ops: ops}) do
    ops
    |> Enum.flat_map(fn
      {:put_node, key, labels, _} -> [Canvas.kind(labels, key)]
      _ -> []
    end)
    |> Enum.uniq()
  end

  defp record(state, delta, entry, now) do
    {nodes, edges} =
      Enum.reduce(delta.ops, {0, 0}, fn
        {:put_node, _, _, _}, {n, e} -> {n + 1, e}
        {:put_edge, _, _, _, _}, {n, e} -> {n, e + 1}
        _, acc -> acc
      end)

    stats =
      state.origins
      |> Map.get(delta.origin, new_stats())
      |> Map.update!(:deltas, &(&1 + 1))
      |> Map.update!(:ops, &(&1 + entry.ops))
      |> Map.update!(:nodes, &(&1 + nodes))
      |> Map.update!(:edges, &(&1 + edges))
      |> Map.update!(:last_seq, &max(&1, delta.seq))
      |> Map.put(:last_ts, delta.ts)
      |> Map.put(:last_seen_at, now)
      |> record_lag(entry.lag_ms)

    %{
      state
      | origins: Map.put(state.origins, delta.origin, stats),
        ring: Enum.take([entry | state.ring], state.ring_size)
    }
  end

  defp new_stats do
    %{
      deltas: 0,
      ops: 0,
      nodes: 0,
      edges: 0,
      last_seq: 0,
      last_ts: nil,
      last_seen_at: nil,
      lag: []
    }
  end

  defp record_lag(stats, nil), do: stats
  defp record_lag(stats, lag), do: %{stats | lag: Enum.take([lag | stats.lag], @lag_samples)}

  defp origin_row(origin, stats, me, now) do
    %{
      origin: origin,
      local?: origin == me,
      deltas: stats.deltas,
      ops: stats.ops,
      nodes: stats.nodes,
      edges: stats.edges,
      last_seq: stats.last_seq,
      last_ts: stats.last_ts,
      age_ms: stats.last_seen_at && now - stats.last_seen_at,
      lag_p50_ms: percentile(stats.lag, 0.5),
      lag_max_ms: Enum.max(stats.lag, fn -> nil end)
    }
  end

  defp percentile([], _), do: nil

  defp percentile(samples, p) do
    sorted = Enum.sort(samples)
    Enum.at(sorted, min(round(p * (length(sorted) - 1)), length(sorted) - 1))
  end

  # ===========================================================================
  # Announcing
  # ===========================================================================

  # One message per delta, until a window fills — then one message per window
  # saying how many, so a replay does not become a thousand LiveView renders.
  defp announce(state, entry, now) do
    {window, count} = state.burst
    {window, count} = if now - window > @burst_window_ms, do: {now, 1}, else: {window, count + 1}

    cond do
      count <= @burst_limit -> broadcast(state, {:hive_delta, entry})
      rem(count, @burst_limit) == 1 -> broadcast(state, {:hive_burst, count})
      true -> :ok
    end

    %{state | burst: {window, count}}
  end

  defp broadcast(state, message) do
    Phoenix.PubSub.broadcast(JidoSwarm.PubSub, state.pubsub_topic, message)
  end

  defp now, do: System.system_time(:millisecond)
end
