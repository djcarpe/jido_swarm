defmodule Jido.Context.Graph do
  @moduledoc """
  One agent's context and knowledge graph: a Glider database, a Lamport clock,
  and a subscription to a mesh.

  This is the process that owns everything. Glider serialises calls against a
  handle internally — the graph is mutated in place, so concurrent access would
  be a data race — and a single owning GenServer satisfies that without ever
  contending on the NIF's mutex.

  Prefer the `Jido.Context` facade; this module is what it talks to.

  ## Two kinds of thing in one graph

  **Knowledge** is what the agents believe about the world: entities and the
  relations between them, meant to outlive any one task.

      Jido.Context.assert(graph, "paper:attention", ["Paper"], %{year: 2017})
      Jido.Context.relate(graph, "paper:attention", "CITES", "paper:seq2seq")

  **Context** is what is true of a particular piece of work: observations
  scoped to a session, a task, a conversation.

      Jido.Context.remember(graph, "task:42", "budget_remaining", 3)

  Both are nodes in one graph, which is the point — an agent can ask what it
  knows *and* what it is doing in a single traversal.

  ## Internal properties

  Every managed entity carries the replication stamp, and user properties may
  not begin with an underscore:

  | Property | Meaning |
  |---|---|
  | `_key` | the mesh-wide identity of this node |
  | `_seq`, `_origin` | the stamp that decides last-writer-wins |
  | `_topic` | the topic the writing delta was published on |
  | `_ts` | wall-clock time of the write, in ms |

  Managed nodes also carry the `:Ctx` label, alongside whatever labels the
  caller gave them, and `:Ctx(_key)` is indexed. A deleted node leaves a
  `:CtxTomb` node behind holding the stamp of its deletion, so a stale assert
  arriving later cannot resurrect it. Tombstones are the only `:CtxTomb` nodes
  and are invisible to `:Ctx` queries.

  ## Durability

  Two independent things, worth keeping apart:

  * **The graph file.** With `location: {:disk, path: ...}` Glider opens a
    `.gldb` that is a write-ahead log and the persistent form at once. This is
    what survives a restart.
  * **The snapshot.** A JSON Lines dump written to a `Jido.Context.Store`. This
    is what *moves* — it is engine-independent and is what goes to S3, so a new
    agent anywhere can boot with what the mesh already knew.
  """

  use GenServer

  require Logger

  alias Jido.Context.Cypher
  alias Jido.Context.Delta
  alias Jido.Context.Engine
  alias Jido.Context.Mesh
  alias Jido.Context.Store

  @node_label "Ctx"
  @tomb_label "CtxTomb"
  @key_prop "_key"

  defmodule State do
    @moduledoc false
    @type t :: %__MODULE__{}
    defstruct [
      :name,
      :engine,
      :handle,
      :origin,
      :store,
      :mesh,
      :topics,
      :default_topic,
      :snapshot_key,
      :snapshot_every,
      :snapshot_interval,
      lamport: 0,
      writes_since_snapshot: 0
    ]
  end

  # ===========================================================================
  # Lifecycle
  # ===========================================================================

  @doc """
  Starts a graph.

  ## Options

  * `:name` — required. Registered name and default origin.
  * `:origin` — the mesh-wide identity of this graph. Defaults to `:name`.
    Must be unique across the mesh: two graphs sharing an origin will tie in
    the last-writer-wins ordering and diverge.
  * `:location` — `:memory` (default) or `{:disk, path: "...", sync: :normal}`.
  * `:store` — a `Jido.Context.Store` spec for snapshots. Optional; without one
    the graph never snapshots.
  * `:mesh` — the name of a running `Jido.Context.Mesh`. Optional; without one
    the graph is private.
  * `:topics` — patterns to subscribe to. Default `["**"]`.
  * `:default_topic` — topic for writes that do not name one. Default `"context"`.
  * `:snapshot_every` — snapshot after this many local writes. Default `:never`.
  * `:snapshot_interval` — snapshot every N ms. Default `:never`.
  * `:restore` — `true` (default) to load a snapshot from the store on boot.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: process_name(name))
  end

  @doc false
  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.fetch!(opts, :name)},
      start: {__MODULE__, :start_link, [opts]},
      type: :worker
    }
  end

  @doc false
  @spec process_name(atom() | String.t()) :: atom()
  def process_name(name) when is_atom(name), do: :"#{name}.Graph"
  def process_name(name) when is_binary(name), do: :"#{name}.Graph"

  @impl true
  def init(opts) do
    # A graph holds a Glider handle and, when disk-backed, a file lock. Trapping
    # exits is what makes `terminate/2` run when the process that started this
    # one goes away — without it a normal exit signal from a linked parent is
    # ignored, and the handle and lock outlive the agent that owned them.
    Process.flag(:trap_exit, true)

    name = Keyword.fetch!(opts, :name)
    engine = Keyword.get(opts, :engine, Engine.default())
    location = normalize_location(Keyword.get(opts, :location, :memory))

    with {:ok, handle} <- engine.open(location),
         :ok <- ensure_indexes(engine, handle) do
      state = %State{
        name: name,
        engine: engine,
        handle: handle,
        origin: to_string(Keyword.get(opts, :origin, name)),
        store: opts |> Keyword.get(:store) |> normalize_store(),
        mesh: Keyword.get(opts, :mesh),
        topics: Keyword.get(opts, :topics, ["**"]),
        default_topic: Keyword.get(opts, :default_topic, "context"),
        snapshot_key: Keyword.get(opts, :snapshot_key, "snapshots/#{name}.jsonl"),
        snapshot_every: Keyword.get(opts, :snapshot_every, :never),
        snapshot_interval: Keyword.get(opts, :snapshot_interval, :never)
      }

      state =
        if Keyword.get(opts, :restore, true), do: restore_snapshot(state), else: state

      if state.mesh, do: Mesh.subscribe(state.mesh, state.topics)
      schedule_snapshot(state)

      {:ok, state}
    else
      {:error, reason} -> {:stop, {:graph_open_failed, reason}}
    end
  end

  defp normalize_location(:memory), do: :memory

  defp normalize_location({:disk, opts}) do
    {:file, Keyword.fetch!(opts, :path), Keyword.get(opts, :sync, :normal)}
  end

  defp normalize_location({:file, _path, _sync} = location), do: location

  defp normalize_store(nil), do: nil
  defp normalize_store(spec), do: Store.normalize(spec)

  # `:Ctx(_key)` is the only lookup path that matters: every upsert starts with
  # it, and without the index each one is a linear label scan.
  defp ensure_indexes(engine, handle) do
    with {:ok, _} <- engine.run(handle, "INDEX ON :#{@node_label}(#{@key_prop})"),
         {:ok, _} <- engine.run(handle, "INDEX ON :#{@tomb_label}(#{@key_prop})") do
      :ok
    end
  end

  @impl true
  def terminate(_reason, %State{} = state) do
    # A snapshot on the way out is best-effort: a graph being shut down because
    # its store is unreachable must not hang the supervisor.
    if state.store, do: snapshot_now(state)
    state.engine.close(state.handle)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  # ===========================================================================
  # Writes
  # ===========================================================================

  @doc "Upserts a node."
  @spec assert_node(atom(), String.t(), [String.t()], map(), keyword()) ::
          {:ok, Delta.t()} | {:error, term()}
  def assert_node(graph, key, labels, props, opts \\ []) do
    commit(graph, [{:put_node, key, labels, stringify(props)}], opts)
  end

  @doc "Upserts an edge, creating placeholder endpoints if they are not there yet."
  @spec assert_edge(atom(), String.t(), String.t(), String.t(), map(), keyword()) ::
          {:ok, Delta.t()} | {:error, term()}
  def assert_edge(graph, from, type, to, props, opts \\ []) do
    commit(graph, [{:put_edge, from, type, to, stringify(props)}], opts)
  end

  @doc "Deletes a node and its edges, leaving a tombstone."
  @spec retract_node(atom(), String.t(), keyword()) :: {:ok, Delta.t()} | {:error, term()}
  def retract_node(graph, key, opts \\ []), do: commit(graph, [{:drop_node, key}], opts)

  @doc "Deletes an edge."
  @spec retract_edge(atom(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, Delta.t()} | {:error, term()}
  def retract_edge(graph, from, type, to, opts \\ []) do
    commit(graph, [{:drop_edge, from, type, to}], opts)
  end

  @doc """
  Applies several operations as one delta.

  A batch is atomic with respect to the mesh: peers see all of it or none of
  it, which matters when a node and the edge that gives it meaning must arrive
  together.
  """
  @spec commit(atom(), [Delta.op()], keyword()) :: {:ok, Delta.t()} | {:error, term()}
  def commit(graph, ops, opts \\ []) do
    GenServer.call(process_name(graph), {:commit, ops, opts}, timeout(opts))
  end

  @doc "Applies a delta that arrived from the mesh. Never republished."
  @spec apply_delta(atom(), Delta.t()) :: :ok
  def apply_delta(graph, %Delta{} = delta) do
    GenServer.cast(process_name(graph), {:apply_delta, delta})
  end

  # ===========================================================================
  # Reads
  # ===========================================================================

  @doc "Runs a raw Cypher query."
  @spec query(atom(), String.t(), keyword()) :: {:ok, Engine.result()} | {:error, term()}
  def query(graph, cypher, opts \\ []) do
    GenServer.call(process_name(graph), {:query, cypher}, timeout(opts))
  end

  @doc "Fetches one node by key."
  @spec fetch(atom(), String.t(), keyword()) :: {:ok, map()} | :not_found | {:error, term()}
  def fetch(graph, key, opts \\ []) do
    GenServer.call(process_name(graph), {:fetch, key}, timeout(opts))
  end

  @doc "Node, edge and label counts."
  @spec stats(atom(), keyword()) :: {:ok, map()} | {:error, term()}
  def stats(graph, opts \\ []), do: GenServer.call(process_name(graph), :stats, timeout(opts))

  @doc "Dumps the whole graph as JSON Lines."
  @spec export(atom(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def export(graph, opts \\ []), do: GenServer.call(process_name(graph), :export, timeout(opts))

  @doc "Writes a snapshot to the configured store."
  @spec snapshot(atom(), keyword()) :: :ok | {:error, term()}
  def snapshot(graph, opts \\ []),
    do: GenServer.call(process_name(graph), :snapshot, timeout(opts))

  @doc "This graph's origin, as it appears in delta stamps."
  @spec origin(atom()) :: String.t()
  def origin(graph), do: GenServer.call(process_name(graph), :origin)

  @doc """
  Blocks until every delta already delivered to this graph has been applied.

  Mesh delivery is asynchronous, so a test that publishes on one graph and
  reads from another needs a barrier rather than a sleep.
  """
  @spec sync(atom(), timeout()) :: :ok
  def sync(graph, timeout \\ 5_000), do: GenServer.call(process_name(graph), :sync, timeout)

  defp timeout(opts), do: Keyword.get(opts, :timeout, 15_000)

  # ===========================================================================
  # Server
  # ===========================================================================

  @impl true
  def handle_call({:commit, ops, opts}, _from, state) do
    topic = Keyword.get(opts, :topic, state.default_topic)

    try do
      lamport = state.lamport + 1
      delta = Delta.new(topic, state.origin, lamport, ops)
      state = %{state | lamport: lamport}

      case apply_ops(state, delta) do
        {:ok, state} ->
          if state.mesh, do: Mesh.publish(state.mesh, delta)
          {:reply, {:ok, delta}, maybe_snapshot(state)}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    rescue
      e in ArgumentError -> {:reply, {:error, Exception.message(e)}, state}
    end
  end

  def handle_call({:query, cypher}, _from, state) do
    {:reply, state.engine.query(state.handle, cypher), state}
  end

  def handle_call({:fetch, key}, _from, state) do
    {:reply, do_fetch(state, key), state}
  end

  def handle_call(:stats, _from, state) do
    {:reply, state.engine.stats(state.handle), state}
  end

  def handle_call(:export, _from, state) do
    {:reply, state.engine.export(state.handle), state}
  end

  def handle_call(:snapshot, _from, state) do
    {:reply, snapshot_now(state), %{state | writes_since_snapshot: 0}}
  end

  def handle_call(:origin, _from, state), do: {:reply, state.origin, state}

  def handle_call(:sync, _from, state), do: {:reply, :ok, state}

  @impl true
  def handle_cast({:apply_delta, delta}, state), do: {:noreply, receive_delta(state, delta)}

  @impl true
  def handle_info({:jido_context_delta, _mesh, %Delta{} = delta}, state) do
    {:noreply, receive_delta(state, delta)}
  end

  def handle_info(:snapshot_tick, state) do
    state =
      if state.store do
        snapshot_now(state)
        %{state | writes_since_snapshot: 0}
      else
        state
      end

    schedule_snapshot(state)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # A delta from our own origin is one we already applied before publishing it.
  defp receive_delta(%State{origin: origin} = state, %Delta{origin: origin}), do: state

  defp receive_delta(state, %Delta{} = delta) do
    # Lamport: anything we write after this must sort after what we just saw.
    state = %{state | lamport: max(state.lamport, delta.seq) + 1}

    case apply_ops(state, delta) do
      {:ok, state} ->
        state

      {:error, reason} ->
        Logger.warning(
          "jido context graph #{inspect(state.name)}: could not apply #{delta.id} " <>
            "from #{delta.origin}: #{inspect(reason)}"
        )

        state
    end
  end

  # ===========================================================================
  # Applying operations
  # ===========================================================================

  defp apply_ops(state, %Delta{} = delta) do
    Enum.reduce_while(delta.ops, {:ok, state}, fn op, {:ok, acc} ->
      case apply_op(acc, delta, op) do
        {:ok, acc} -> {:cont, {:ok, acc}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp apply_op(state, delta, {:put_node, key, labels, props}) do
    stamp = {delta.seq, delta.origin}

    with {:ok, tomb} <- read_stamp(state, @tomb_label, key) do
      if tomb && Delta.compare_stamp(tomb, stamp) != :lt do
        # The node was deleted by a write that wins over this one.
        {:ok, state}
      else
        with {:ok, state} <- write_node(state, delta, key, labels, props),
             :ok <- clear_tombstone(state, key, tomb) do
          {:ok, state}
        end
      end
    end
  end

  defp apply_op(state, delta, {:drop_node, key}) do
    stamp = {delta.seq, delta.origin}

    with {:ok, existing} <- read_stamp(state, @node_label, key) do
      if existing && Delta.compare_stamp(existing, stamp) == :gt do
        {:ok, state}
      else
        with {:ok, _} <-
               run(state, "MATCH (n#{label(@node_label)} #{key_match(key)}) DETACH DELETE n") do
          write_tombstone(state, delta, key)
        end
      end
    end
  end

  defp apply_op(state, delta, {:put_edge, from, type, to, props}) do
    stamp = {delta.seq, delta.origin}

    with {:ok, state} <- ensure_endpoint(state, delta, from),
         {:ok, state} <- ensure_endpoint(state, delta, to),
         {:ok, existing} <- read_edge_stamp(state, from, type, to) do
      cond do
        is_nil(existing) ->
          create_edge(state, delta, from, type, to, props)

        Delta.compare_stamp(existing, stamp) == :lt ->
          update_edge(state, delta, from, type, to, props)

        true ->
          {:ok, state}
      end
    end
  end

  defp apply_op(state, delta, {:drop_edge, from, type, to}) do
    stamp = {delta.seq, delta.origin}

    with {:ok, existing} <- read_edge_stamp(state, from, type, to) do
      if existing && Delta.compare_stamp(existing, stamp) == :gt do
        {:ok, state}
      else
        with {:ok, _} <- run(state, edge_match(from, type, to) <> " DELETE r") do
          {:ok, state}
        end
      end
    end
  end

  # An edge can arrive before the nodes it connects — a peer may have published
  # them on a different topic, or in a delta still in flight. A placeholder node
  # carries no labels and the stamp of the edge that needed it, so a later, real
  # assert of that node wins the comparison and fills it in.
  defp ensure_endpoint(state, delta, key) do
    with {:ok, existing} <- read_stamp(state, @node_label, key) do
      if existing do
        {:ok, state}
      else
        write_node(state, delta, key, [], %{})
      end
    end
  end

  defp write_node(state, delta, key, labels, props) do
    with {:ok, existing} <- read_stamp(state, @node_label, key) do
      stamp = {delta.seq, delta.origin}

      cond do
        is_nil(existing) ->
          create_node(state, delta, key, labels, props)

        Delta.compare_stamp(existing, stamp) == :lt ->
          update_node(state, delta, key, labels, props)

        true ->
          {:ok, state}
      end
    end
  end

  defp create_node(state, delta, key, labels, props) do
    all_props = Map.merge(props, stamp_props(delta, key))
    all_labels = [@node_label | Enum.map(labels, &Cypher.identifier!/1)] |> Enum.uniq()

    statement = "CREATE (n#{Cypher.labels(all_labels)} #{Cypher.props(all_props)})"

    with {:ok, _} <- run(state, statement), do: {:ok, state}
  end

  defp update_node(state, delta, key, labels, props) do
    all_props = Map.merge(props, stamp_props(delta, key))

    set_clause =
      [Cypher.set_props("n", all_props), label_set("n", labels)]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(", ")

    statement = "MATCH (n#{label(@node_label)} #{key_match(key)}) SET #{set_clause}"

    with {:ok, _} <- run(state, statement), do: {:ok, state}
  end

  defp label_set(_var, []), do: nil

  defp label_set(var, labels) do
    Enum.map_join(labels, ", ", fn label -> "#{var}:#{Cypher.identifier!(label)}" end)
  end

  defp create_edge(state, delta, from, type, to, props) do
    all_props = Map.merge(props, edge_stamp_props(delta))

    statement =
      "MATCH (a#{label(@node_label)} #{key_match(from)}), (b#{label(@node_label)} #{key_match(to)}) " <>
        "CREATE (a)-[:#{Cypher.identifier!(type)} #{Cypher.props(all_props)}]->(b)"

    with {:ok, _} <- run(state, statement), do: {:ok, state}
  end

  defp update_edge(state, delta, from, type, to, props) do
    all_props = Map.merge(props, edge_stamp_props(delta))
    statement = edge_match(from, type, to) <> " SET " <> Cypher.set_props("r", all_props)

    with {:ok, _} <- run(state, statement), do: {:ok, state}
  end

  defp write_tombstone(state, delta, key) do
    props = stamp_props(delta, key)

    with {:ok, existing} <- read_stamp(state, @tomb_label, key) do
      statement =
        if existing do
          "MATCH (t#{label(@tomb_label)} #{key_match(key)}) SET " <> Cypher.set_props("t", props)
        else
          "CREATE (t#{label(@tomb_label)} #{Cypher.props(props)})"
        end

      with {:ok, _} <- run(state, statement), do: {:ok, state}
    end
  end

  defp clear_tombstone(_state, _key, nil), do: :ok

  defp clear_tombstone(state, key, _tomb) do
    with {:ok, _} <-
           run(state, "MATCH (t#{label(@tomb_label)} #{key_match(key)}) DETACH DELETE t") do
      :ok
    end
  end

  # An edge is identified by its endpoints and type, so it carries the stamp
  # but no `_key` of its own.
  defp edge_stamp_props(delta) do
    %{
      "_seq" => delta.seq,
      "_origin" => delta.origin,
      "_topic" => delta.topic,
      "_ts" => delta.ts
    }
  end

  defp stamp_props(delta, key) do
    %{
      @key_prop => key,
      "_seq" => delta.seq,
      "_origin" => delta.origin,
      "_topic" => delta.topic,
      "_ts" => delta.ts
    }
  end

  # ===========================================================================
  # Reading stamps
  # ===========================================================================

  defp read_stamp(state, label_name, key) do
    statement =
      "MATCH (n#{label(label_name)} #{key_match(key)}) RETURN n._seq, n._origin LIMIT 1"

    case state.engine.query(state.handle, statement) do
      {:ok, %{rows: [[seq, origin] | _]}} when is_integer(seq) and is_binary(origin) ->
        {:ok, {seq, origin}}

      {:ok, _} ->
        {:ok, nil}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp read_edge_stamp(state, from, type, to) do
    statement = edge_match(from, type, to) <> " RETURN r._seq, r._origin LIMIT 1"

    case state.engine.query(state.handle, statement) do
      {:ok, %{rows: [[seq, origin] | _]}} when is_integer(seq) and is_binary(origin) ->
        {:ok, {seq, origin}}

      {:ok, _} ->
        {:ok, nil}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_fetch(state, key) do
    statement = "MATCH (n#{label(@node_label)} #{key_match(key)}) RETURN n LIMIT 1"

    case state.engine.query(state.handle, statement) do
      {:ok, %{rows: [[node] | _]}} -> {:ok, node}
      {:ok, _} -> :not_found
      {:error, reason} -> {:error, reason}
    end
  end

  defp label(name), do: ":" <> name

  defp key_match(key), do: "{#{@key_prop}: #{Cypher.encode_value(key)}}"

  defp edge_match(from, type, to) do
    "MATCH (a#{label(@node_label)} #{key_match(from)})-[r:#{Cypher.identifier!(type)}]->" <>
      "(b#{label(@node_label)} #{key_match(to)})"
  end

  defp run(state, statement), do: state.engine.run(state.handle, statement)

  # ===========================================================================
  # Snapshots
  # ===========================================================================

  defp restore_snapshot(%State{store: nil} = state), do: state

  defp restore_snapshot(state) do
    case Store.get(state.store, state.snapshot_key) do
      {:ok, jsonl} when byte_size(jsonl) > 0 ->
        case state.engine.import(state.handle, jsonl) do
          {:ok, _} ->
            Logger.debug("jido context graph #{inspect(state.name)}: restored a snapshot")
            %{state | lamport: max_seq(state)}

          {:error, reason} ->
            Logger.warning(
              "jido context graph #{inspect(state.name)}: snapshot restore failed: " <>
                inspect(reason)
            )

            state
        end

      _ ->
        state
    end
  end

  # After a restore the clock must resume above every stamp in the graph, or
  # this origin would re-issue sequence numbers it has already used and lose the
  # comparison against its own earlier writes.
  defp max_seq(state) do
    statement = "MATCH (n#{label(@node_label)}) RETURN max(n._seq)"

    case state.engine.query(state.handle, statement) do
      {:ok, %{rows: [[seq] | _]}} when is_integer(seq) -> seq
      _ -> 0
    end
  end

  defp maybe_snapshot(%State{store: nil} = state), do: state

  defp maybe_snapshot(%State{snapshot_every: :never} = state), do: state

  defp maybe_snapshot(%State{snapshot_every: every} = state) when is_integer(every) do
    writes = state.writes_since_snapshot + 1

    if writes >= every do
      snapshot_now(state)
      %{state | writes_since_snapshot: 0}
    else
      %{state | writes_since_snapshot: writes}
    end
  end

  defp snapshot_now(%State{store: nil}), do: {:error, :no_store}

  defp snapshot_now(state) do
    with {:ok, jsonl} <- state.engine.export(state.handle),
         :ok <- Store.put(state.store, state.snapshot_key, jsonl) do
      state.engine.checkpoint(state.handle)
      :ok
    else
      {:error, reason} ->
        Logger.warning(
          "jido context graph #{inspect(state.name)}: snapshot failed: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp schedule_snapshot(%State{snapshot_interval: :never}), do: :ok

  defp schedule_snapshot(%State{snapshot_interval: ms}) when is_integer(ms) do
    Process.send_after(self(), :snapshot_tick, ms)
    :ok
  end

  defp stringify(props) when is_map(props) do
    Map.new(props, fn {k, v} -> {to_string(k), v} end)
  end
end
