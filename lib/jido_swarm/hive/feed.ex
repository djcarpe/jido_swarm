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

  ## The probe

  "Replicated" is a claim until you can watch it. `probe/1` writes one node
  from this pod; every other pod's feed, on seeing it arrive, writes an
  acknowledgement back *through the same graph*, and this feed times the round
  trip when the acknowledgement lands. Nothing outside the graph carries the
  answer, so an ack on screen is proof the write went out and the reply came
  back the same way every insight does.

  ## The conflict

  `conflict/1` writes one key from this pod and, over `:erpc`, from another,
  as close together as a call allows. Both replicas keep whichever write has
  the higher stamp — sequence, then origin — and the console shows which and
  why. It is the convergence rule made visible, not a race that could go
  either way.

  ## What the rule decided

  A delta arriving here is not the same as a delta applied: `Jido.Context`
  keeps whichever write of an entity carries the higher stamp and drops the
  other whole. The graph reports that as telemetry, and this feed listens —
  when a delta loses, in part or in full, the entry on the ticker is marked
  and `{:hive_outcome, ...}` names the keys, so the console can show the
  losing write and re-read what actually survived.

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

  alias JidoSwarm.Hive.Store

  @default_topics ["hive.**", "knowledge.**", "context.**"]
  @default_ring 200
  @lag_samples 64

  @probe_label "HiveProbe"
  @ack_label "HiveProbeAck"
  @probe_timeout_ms 5_000
  @probes_kept 10
  # Probes and acks are the only Hive entities nobody needs later; each pod
  # removes its own once they are an hour old.
  @sweep_every_ms 600_000
  @sweep_after_ms 3_600_000
  @peer_timeout_ms 1_000

  @conflict_key "demo:conflict"
  @conflict_label "HiveDemo"

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
    Process.send_after(self(), :sweep, @sweep_every_ms)

    # The graph and the router run these in their own processes; only what
    # this feed needs to hear about becomes a message.
    handler = "hive-feed-#{inspect(Keyword.get(opts, :name, __MODULE__))}"
    :telemetry.detach(handler)

    :ok =
      :telemetry.attach_many(
        handler,
        [[:jido, :context, :delta, :applied], [:jido, :context, :mesh, :duplicate]],
        &__MODULE__.handle_telemetry/4,
        %{feed: self(), graph: graph, mesh: mesh}
      )

    Process.flag(:trap_exit, true)

    {:ok,
     %{
       name: Keyword.get(opts, :name, __MODULE__),
       graph: graph,
       mesh: mesh,
       origin: Jido.Context.Graph.origin(graph),
       node: node(),
       since: now(),
       pubsub_topic: Keyword.get(opts, :pubsub_topic, "hive"),
       ring_size: Keyword.get(opts, :ring, @default_ring),
       ring: [],
       origins: %{},
       burst: {0, 0},
       probes: %{},
       handler: handler
     }}
  end

  @impl true
  def terminate(_reason, state), do: :telemetry.detach(state.handler)

  @doc false
  # Runs inside the graph or the router. Cheap by construction: a map lookup
  # and, only when a write lost, one message.
  def handle_telemetry([:jido, :context, :delta, :applied], m, %{graph: graph} = meta, %{
        feed: feed,
        graph: graph
      }) do
    if m.superseded + m.tombstoned > 0 do
      send(feed, {:delta_outcome, meta.id, meta.origin, meta.outcomes})
    end

    :ok
  end

  def handle_telemetry([:jido, :context, :mesh, :duplicate], _m, %{mesh: mesh} = meta, %{
        feed: feed,
        mesh: mesh
      }) do
    send(feed, {:duplicate, meta.origin})
    :ok
  end

  def handle_telemetry(_event, _m, _meta, _config), do: :ok

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
      name
      |> remote_identities(timeout)
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

  @doc """
  Writes a probe from this replica and waits for the other pods to answer
  through the graph. Returns the probe's id; watch `probes/1` or the
  `{:hive_probe, probe}` broadcasts for the acknowledgements as they land.
  """
  @spec probe(GenServer.server()) :: {:ok, String.t()} | {:error, term()}
  def probe(server \\ __MODULE__), do: GenServer.call(server, :probe)

  @doc """
  The last #{@probes_kept} probes, newest first, each with the origins it
  expected an answer from, the acknowledgements so far with their round-trip
  and one-way times, and whether it timed out.
  """
  @spec probes(GenServer.server()) :: [map()]
  def probes(server \\ __MODULE__), do: GenServer.call(server, :probes)

  @doc """
  Writes `#{@conflict_key}` from this pod and from one other, so the operator
  can watch last-writer-wins pick one. Returns both writes' stamps; read the
  key a moment later to see which survived on every replica.
  """
  @spec conflict(GenServer.server()) :: {:ok, map()} | {:error, :no_peers | term()}
  def conflict(server \\ __MODULE__), do: GenServer.call(server, :conflict)

  @doc "The other side of `conflict/1`: writes the demo key from this replica."
  @spec write_conflict(GenServer.server(), String.t()) ::
          {:ok, %{seq: non_neg_integer(), origin: String.t()}} | {:error, term()}
  def write_conflict(server \\ __MODULE__, key),
    do: GenServer.call(server, {:write_conflict, key})

  @doc """
  Why one stamp beat another, in a sentence.

      iex> JidoSwarm.Hive.Feed.explain({57, "pod-a"}, {55, "pod-b"})
      "pod-a's write carried sequence 57 against pod-b's 55: the higher clock wins."

      iex> JidoSwarm.Hive.Feed.explain({9, "pod-b"}, {9, "pod-a"})
      "Both writes carried sequence 9, so the origin breaks the tie: \\"pod-b\\" sorts after \\"pod-a\\"."
  """
  @spec explain({non_neg_integer(), String.t()}, {non_neg_integer(), String.t()}) :: String.t()
  def explain({seq, winner}, {seq, loser}) do
    "Both writes carried sequence #{seq}, so the origin breaks the tie: " <>
      "#{inspect(winner)} sorts after #{inspect(loser)}."
  end

  def explain({ws, winner}, {ls, loser}) do
    "#{winner}'s write carried sequence #{ws} against #{loser}'s #{ls}: the higher clock wins."
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
    {:reply, :ok, %{state | ring: [], origins: %{}, burst: {0, 0}, probes: %{}}}
  end

  def handle_call(:probe, _from, state) do
    id = Store.new_id("p")
    now = now()

    expected =
      remote_identities(state.name, @peer_timeout_ms)
      |> Enum.flat_map(fn
        {:ok, %{origin: origin}} -> [origin]
        _ -> []
      end)

    ops = [
      {:put_node, "probe:" <> id, [@probe_label], %{"origin" => state.origin, "sent_at" => now}}
    ]

    case Jido.Context.commit(state.graph, ops, topic: Store.topic(:signals)) do
      {:ok, _} ->
        probe = %{
          id: id,
          key: "probe:" <> id,
          sent_at: now,
          expected: expected,
          acks: [],
          timed_out: false
        }

        Process.send_after(self(), {:probe_timeout, id}, @probe_timeout_ms)
        {:reply, {:ok, id}, put_probe(state, probe)}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  def handle_call(:probes, _from, state) do
    {:reply, probe_list(state), state}
  end

  def handle_call(:conflict, _from, state) do
    peers =
      remote_identities(state.name, @peer_timeout_ms)
      |> Enum.zip(Node.list())
      |> Enum.flat_map(fn
        {{:ok, %{origin: origin}}, node} -> [{node, origin}]
        _ -> []
      end)

    case peers do
      [] ->
        {:reply, {:error, :no_peers}, state}

      [{node, _origin} | _] ->
        with {:ok, mine} <- write_demo(state.graph, state.origin, @conflict_key),
             {:ok, theirs} <-
               :erpc.call(
                 node,
                 __MODULE__,
                 :write_conflict,
                 [state.name, @conflict_key],
                 @peer_timeout_ms
               ) do
          {:reply, {:ok, %{key: @conflict_key, mine: mine, theirs: theirs}}, state}
        else
          error -> {:reply, {:error, error}, state}
        end
    end
  end

  def handle_call({:write_conflict, key}, _from, state) do
    {:reply, write_demo(state.graph, state.origin, key), state}
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
      |> react(delta, now)

    {:noreply, state}
  end

  def handle_info({:probe_timeout, id}, state) do
    case state.probes[id] do
      %{acks: acks, expected: expected} = probe when length(acks) < length(expected) ->
        probe = %{probe | timed_out: true}
        broadcast(state, {:hive_probe, probe})
        {:noreply, put_probe(state, probe)}

      _ ->
        {:noreply, state}
    end
  end

  # The graph applied a delta and some of it lost. The ring entry is marked,
  # the origin's tally grows, and the console is told which keys to re-read.
  def handle_info({:delta_outcome, id, origin, outcomes}, state) do
    lost = fn wanted, keys -> for {key, ^wanted} <- Enum.zip(keys, outcomes), do: key end

    {ring, keys} =
      Enum.map_reduce(state.ring, [], fn
        %{id: ^id} = entry, _ -> {%{entry | outcome: Enum.frequencies(outcomes)}, entry.keys}
        entry, acc -> {entry, acc}
      end)

    superseded = lost.(:superseded, keys)
    tombstoned = lost.(:tombstoned, keys)

    stats =
      state.origins
      |> Map.get(origin, new_stats())
      |> Map.update!(:superseded, &(&1 + length(superseded)))
      |> Map.update!(:tombstoned, &(&1 + length(tombstoned)))

    broadcast(
      state,
      {:hive_outcome, %{id: id, origin: origin, superseded: superseded, tombstoned: tombstoned}}
    )

    {:noreply, %{state | ring: ring, origins: Map.put(state.origins, origin, stats)}}
  end

  def handle_info({:duplicate, origin}, state) do
    stats = state.origins |> Map.get(origin, new_stats()) |> Map.update!(:duplicates, &(&1 + 1))
    {:noreply, %{state | origins: Map.put(state.origins, origin, stats)}}
  end

  def handle_info(:sweep, state) do
    Process.send_after(self(), :sweep, @sweep_every_ms)
    sweep(state)
    cutoff = now() - @sweep_after_ms
    probes = state.probes |> Enum.reject(fn {_, p} -> p.sent_at < cutoff end) |> Map.new()
    {:noreply, %{state | probes: probes}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ===========================================================================
  # Probes
  # ===========================================================================

  # Another pod's probe gets an acknowledgement written back through the
  # graph; an acknowledgement of one of ours gets timed.
  defp react(state, %Delta{origin: origin}, _now) when origin == state.origin, do: state

  defp react(state, %Delta{} = delta, now) do
    Enum.reduce(delta.ops, state, fn
      {:put_node, "probe:" <> id, labels, props}, acc ->
        if @probe_label in labels, do: acknowledge(acc, id, props, now), else: acc

      {:put_node, "ack:" <> _, labels, props}, acc ->
        if @ack_label in labels, do: timed(acc, delta.origin, props, now), else: acc

      _, acc ->
        acc
    end)
  end

  defp acknowledge(state, id, props, now) do
    key = "ack:#{id}:#{state.origin}"

    ops = [
      {:put_node, key, [@ack_label],
       %{
         "probe" => id,
         "origin" => state.origin,
         "received_at" => now,
         "probe_sent_at" => props["sent_at"]
       }},
      {:put_edge, key, "ACKS", "probe:" <> id, %{}}
    ]

    case Jido.Context.commit(state.graph, ops, topic: Store.topic(:signals)) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("hive feed: could not acknowledge probe #{id}: #{inspect(reason)}")
    end

    state
  end

  defp timed(state, origin, props, now) do
    case state.probes[props["probe"]] do
      nil ->
        state

      probe ->
        if Enum.any?(probe.acks, &(&1.origin == origin)) do
          state
        else
          ack = %{
            origin: origin,
            rtt_ms: max(now - probe.sent_at, 0),
            one_way_ms: props["received_at"] && props["received_at"] - probe.sent_at,
            at: now
          }

          probe = %{probe | acks: probe.acks ++ [ack]}
          broadcast(state, {:hive_probe, probe})
          put_probe(state, probe)
        end
    end
  end

  defp put_probe(state, probe) do
    probes =
      state.probes
      |> Map.put(probe.id, probe)
      |> Enum.sort_by(fn {_, p} -> -p.sent_at end)
      |> Enum.take(@probes_kept)
      |> Map.new()

    %{state | probes: probes}
  end

  defp probe_list(state) do
    state.probes |> Map.values() |> Enum.sort_by(&(-&1.sent_at))
  end

  defp sweep(state) do
    cutoff = now() - @sweep_after_ms

    for {label, field} <- [{@probe_label, "sent_at"}, {@ack_label, "received_at"}],
        %{key: key} <-
          Store.rows(
            "MATCH (n:#{label}) WHERE n._origin = #{Store.lit(state.origin)} AND n.#{field} < #{cutoff} RETURN n._key",
            [:key]
          ) do
      Jido.Context.retract(state.graph, key, topic: Store.topic(:signals))
    end

    :ok
  rescue
    e -> Logger.warning("hive feed: sweep failed: #{Exception.message(e)}")
  end

  defp write_demo(graph, origin, key) do
    props = %{"value" => "written by #{origin}", "at" => now()}

    case Jido.Context.commit(graph, [{:put_node, key, [@conflict_label], props}],
           topic: Store.topic(:signals)
         ) do
      {:ok, %Delta{seq: seq}} -> {:ok, %{seq: seq, origin: origin}}
      {:error, _} = error -> error
    end
  end

  # What every other node's feed reports, in `Node.list/0` order; a node that
  # does not answer in time is an error tuple in its slot.
  defp remote_identities(name, timeout) do
    :erpc.multicall(Node.list(), __MODULE__, :identity, [name], timeout)
  end

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
      kinds: kinds(delta),
      keys: Enum.map(delta.ops, &op_key/1),
      outcome: nil
    }
  end

  defp op_key({:put_node, key, _, _}), do: key
  defp op_key({:drop_node, key}), do: key
  defp op_key({:put_edge, from, type, to, _}), do: "#{from}|#{type}|#{to}"
  defp op_key({:drop_edge, from, type, to}), do: "#{from}|#{type}|#{to}"

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
      superseded: 0,
      tombstoned: 0,
      duplicates: 0,
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
      superseded: stats.superseded,
      tombstoned: stats.tombstoned,
      duplicates: stats.duplicates,
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
