defmodule Jido.Context do
  @moduledoc """
  A shared context and knowledge graph for Jido agents.

  Agents accumulate two things worth keeping: **knowledge** — entities and the
  relations between them, meant to outlive the task that discovered them — and
  **context** — what is true of a particular session, task or conversation.
  Both are graphs, and agents working together need them to be the *same*
  graph. `Jido.Context` is that graph, backed by
  [Glider](https://github.com/agentjido/glider) and replicated across agents by
  topic.

  ## The shape of it

      ┌──────────┐      ┌──────────┐      ┌──────────┐
      │ agent A  │      │ agent B  │      │ agent C  │
      │  graph   │      │  graph   │      │  graph   │
      └────┬─────┘      └────┬─────┘      └────┬─────┘
           │ deltas          │                 │
           └────────────┬────┴─────────────────┘
                        │
                  ┌─────┴──────┐
                  │    mesh    │  routes by topic
                  └─────┬──────┘
             ┌──────────┴──────────┐
             │                     │
          :pg (cluster)      topic log (S3)

  Every agent holds a full graph of its own, in memory or on disk. Writes
  become deltas; the mesh routes them by topic; every subscriber applies them.
  There is no leader and no shared database — an agent reads its own memory at
  NIF speed, and converges with the others asynchronously.

  ## Quick start

      {:ok, _} = Jido.Context.start_mesh(name: :research, transports: [:pg])

      {:ok, _} =
        Jido.Context.start_graph(
          name: :scout,
          mesh: :research,
          topics: ["knowledge.**"]
        )

      Jido.Context.assert(:scout, "paper:attention", ["Paper"],
        %{title: "Attention Is All You Need", year: 2017},
        topic: "knowledge.papers"
      )

      Jido.Context.relate(:scout, "paper:attention", "CITES", "paper:seq2seq",
        topic: "knowledge.papers"
      )

      {:ok, result} =
        Jido.Context.query(:scout, "MATCH (p:Paper) RETURN p.title, p.year")

  ## Where the graph lives

  | `:location` | Behaviour |
  |---|---|
  | `:memory` (default) | nothing touches disk; the graph dies with the process |
  | `{:disk, path: "..."}` | Glider opens a `.gldb` that is its own write-ahead log |

  ## Where it is persisted

  `:store` is separate from `:location` and does a different job: it holds
  JSON Lines snapshots, which are engine-independent and therefore portable.

  | `:store` | Behaviour |
  |---|---|
  | `nil` (default) | no snapshots |
  | `:memory` | snapshots into ETS — useful in tests |
  | `{:disk, path: "..."}` | snapshots as files |
  | `{:s3, bucket: ..., ...}` | snapshots as objects, readable from anywhere |

  A graph with a store restores from its snapshot on boot, so an agent restarts
  knowing what it knew. The three combine as you would expect: an in-memory
  graph that snapshots to S3 is fast to read, durable off-box, and costs no
  local disk.

  ## Streaming across agents

  A mesh carries deltas over any number of transports at once:

      Jido.Context.start_mesh(
        name: :research,
        transports: [
          :pg,
          {:log, store: {:s3, bucket: "graphs", prefix: "research"}, interval: 1_000}
        ]
      )

  `:pg` reaches agents that share a BEAM cluster, in one message send.
  `{:log, store: ...}` writes each delta as an immutable object and polls for
  what others wrote, which reaches agents that share nothing but a bucket — a
  different region, a batch job, an agent that starts tomorrow. Running both is
  the usual production shape: local agents converge instantly, everyone else
  converges within the poll interval.

  ## Topics

  Writes are tagged with a topic and subscribers register patterns:

      topics: ["knowledge.**"]           everything under knowledge
      topics: ["context.session_42"]     one session
      topics: ["knowledge.*", "alerts"]  several

  Topics are how an agent avoids drowning in what it does not need. A planner
  might take `["knowledge.**"]` while a narrow tool agent takes only
  `["context.task_7"]`.

  ## Convergence

  Deltas are stamped `{seq, origin}` — a Lamport clock and a stable per-graph
  identity — and applied last-writer-wins per entity. The order is total and
  every agent computes it identically, so applying the same deltas in any order
  reaches the same graph. Deletes leave tombstones, so a stale assert arriving
  late cannot resurrect a retracted fact. See `Jido.Context.Delta`.

  ## Installing the engine

  Glider is an optional dependency — it is a Rustler NIF and needs a Rust
  toolchain — so add it yourself:

      {:glider_ex, "~> 0.1"}

  Without it, `start_graph/1` fails with `{:engine_unavailable, hint}` rather
  than Jido failing to compile.
  """

  alias Jido.Context.Delta
  alias Jido.Context.Engine
  alias Jido.Context.Graph
  alias Jido.Context.Mesh

  @doc """
  Starts a mesh. See `Jido.Context.Mesh.start_link/1`.
  """
  @spec start_mesh(keyword()) :: Supervisor.on_start()
  defdelegate start_mesh(opts), to: Mesh, as: :start_link

  @doc """
  Starts a graph. See `Jido.Context.Graph.start_link/1`.
  """
  @spec start_graph(keyword()) :: GenServer.on_start()
  defdelegate start_graph(opts), to: Graph, as: :start_link

  @doc """
  Is the graph engine available in this build?

  False means `glider_ex` is not a dependency of the running application.
  """
  @spec available?() :: boolean()
  def available?, do: Engine.default().available?()

  # ===========================================================================
  # Knowledge
  # ===========================================================================

  @doc """
  Asserts an entity: upserts the node identified by `key`.

  `key` is the entity's identity across the whole mesh, so it should be
  something stable and meaningful — `"paper:10.1234/xyz"`, `"user:42"` — not a
  generated id that a second agent could not arrive at independently.

  Properties may not begin with an underscore; those are reserved for the
  replication stamp.

  ## Options

  * `:topic` — the topic to publish on. Defaults to the graph's `:default_topic`.

  ## Example

      Jido.Context.assert(:scout, "paper:attention", ["Paper", "Cited"],
        %{title: "Attention Is All You Need", year: 2017},
        topic: "knowledge.papers"
      )
  """
  @spec assert(atom(), String.t(), [String.t()], map(), keyword()) ::
          {:ok, Delta.t()} | {:error, term()}
  def assert(graph, key, labels \\ [], props \\ %{}, opts \\ []) do
    Graph.assert_node(graph, key, labels, props, opts)
  end

  @doc """
  Relates two entities, upserting the edge.

  Endpoints that do not exist yet are created as unlabelled placeholders, so an
  edge can arrive before the nodes it connects — which happens routinely when
  two agents publish on different topics.

      Jido.Context.relate(:scout, "paper:attention", "CITES", "paper:seq2seq",
        %{section: "related work"}
      )
  """
  @spec relate(atom(), String.t(), String.t(), String.t(), map(), keyword()) ::
          {:ok, Delta.t()} | {:error, term()}
  def relate(graph, from, type, to, props \\ %{}, opts \\ []) do
    Graph.assert_edge(graph, from, type, to, props, opts)
  end

  @doc """
  Retracts an entity, deleting it and its edges across the mesh.

  A tombstone is left behind carrying the stamp of the deletion, so an assert
  that was already in flight cannot bring it back.
  """
  @spec retract(atom(), String.t(), keyword()) :: {:ok, Delta.t()} | {:error, term()}
  defdelegate retract(graph, key, opts \\ []), to: Graph, as: :retract_node

  @doc "Retracts a relation."
  @spec unrelate(atom(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, Delta.t()} | {:error, term()}
  defdelegate unrelate(graph, from, type, to, opts \\ []), to: Graph, as: :retract_edge

  @doc """
  Applies several operations as one delta.

  Peers see all of it or none of it, which matters when a node and the edge
  that gives it meaning must land together.

      Jido.Context.commit(:scout, [
        {:put_node, "run:9", ["Run"], %{status: "ok"}},
        {:put_edge, "run:9", "OF_TASK", "task:42", %{}}
      ], topic: "context.task_42")
  """
  @spec commit(atom(), [Delta.op()], keyword()) :: {:ok, Delta.t()} | {:error, term()}
  defdelegate commit(graph, ops, opts \\ []), to: Graph

  # ===========================================================================
  # Context
  # ===========================================================================

  @doc """
  Records an observation scoped to some unit of work.

  Sugar over `assert/5` and `relate/6`: it writes a `:CtxEntry` node and hangs
  it off a `:CtxScope` node, so everything known about a task is one hop away.

      Jido.Context.remember(:planner, "task:42", "budget_remaining", 3)
      Jido.Context.remember(:planner, "task:42", "owner", "scout")

  The scope node is created on first use. Writing the same `name` again
  overwrites its value, last-writer-wins across the mesh like any other assert.
  """
  @spec remember(atom(), String.t(), String.t(), term(), keyword()) ::
          {:ok, Delta.t()} | {:error, term()}
  def remember(graph, scope, name, value, opts \\ []) do
    entry_key = "#{scope}##{name}"

    commit(
      graph,
      [
        {:put_node, scope, ["CtxScope"], %{"scope" => scope}},
        {:put_node, entry_key, ["CtxEntry"], %{"name" => name, "value" => encode_value(value)}},
        {:put_edge, scope, "HAS_ENTRY", entry_key, %{}}
      ],
      opts
    )
  end

  @doc """
  Everything remembered under a scope, as a map.

      Jido.Context.recall(:planner, "task:42")
      #=> {:ok, %{"budget_remaining" => 3, "owner" => "scout"}}
  """
  @spec recall(atom(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def recall(graph, scope, opts \\ []) do
    statement = """
    MATCH (s:CtxScope {_key: #{Jido.Context.Cypher.encode_value(scope)}})-[:HAS_ENTRY]->(e:CtxEntry)
    RETURN e.name, e.value
    """

    case Graph.query(graph, statement, opts) do
      {:ok, %{rows: rows}} ->
        {:ok, Map.new(rows, fn [name, value] -> {name, decode_value(value)} end)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Forgets one entry in a scope."
  @spec forget(atom(), String.t(), String.t(), keyword()) :: {:ok, Delta.t()} | {:error, term()}
  def forget(graph, scope, name, opts \\ []) do
    retract(graph, "#{scope}##{name}", opts)
  end

  # Glider values are null, bool, int, float, text or a list of those. A map or
  # a tuple has no literal form, so it is stored as JSON text and recovered on
  # read — the round trip is lossy for atoms, which is why it is documented
  # rather than hidden.
  defp encode_value(value)
       when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value),
       do: value

  defp encode_value(value) when is_list(value) do
    if Enum.all?(value, &(is_binary(&1) or is_number(&1) or is_boolean(&1) or is_nil(&1))) do
      value
    else
      JSON.encode!(value)
    end
  end

  defp encode_value(value), do: JSON.encode!(value)

  defp decode_value(value) when is_binary(value) do
    case JSON.decode(value) do
      {:ok, decoded} when is_map(decoded) or is_list(decoded) -> decoded
      _ -> value
    end
  end

  defp decode_value(value), do: value

  # ===========================================================================
  # Reads
  # ===========================================================================

  @doc """
  Runs a Cypher query against the graph.

  The query sees the live graph: tombstones carry the `:CtxTomb` label and no
  other, so a query written against your own labels never encounters one.

      Jido.Context.query(:scout, ~S|MATCH (p:Paper) WHERE p.year > 2015 RETURN p.title|)

  Glider's Cypher is a subset — `MATCH`, `WHERE`, `RETURN`, `CREATE`, `SET`,
  `DELETE`, aggregates, variable-length paths and `CALL` for graph algorithms.
  Note that `RETURN` requires a `MATCH`; there is no bare `RETURN 1`.
  """
  @spec query(atom(), String.t(), keyword()) :: {:ok, Engine.result()} | {:error, term()}
  defdelegate query(graph, cypher, opts \\ []), to: Graph

  @doc "Fetches one entity by key."
  @spec fetch(atom(), String.t(), keyword()) :: {:ok, map()} | :not_found | {:error, term()}
  defdelegate fetch(graph, key, opts \\ []), to: Graph

  @doc "Node, edge, label and index counts."
  @spec stats(atom(), keyword()) :: {:ok, map()} | {:error, term()}
  defdelegate stats(graph, opts \\ []), to: Graph

  @doc "Dumps the whole graph as JSON Lines."
  @spec export(atom(), keyword()) :: {:ok, String.t()} | {:error, term()}
  defdelegate export(graph, opts \\ []), to: Graph

  @doc "Writes a snapshot to the configured store now."
  @spec snapshot(atom(), keyword()) :: :ok | {:error, term()}
  defdelegate snapshot(graph, opts \\ []), to: Graph

  @doc """
  Blocks until every delta delivered to this graph has been applied.

  Mesh delivery is asynchronous. Use this instead of sleeping when you need to
  read on one agent what another just wrote.
  """
  @spec sync(atom(), timeout()) :: :ok
  defdelegate sync(graph, timeout \\ 5_000), to: Graph
end
