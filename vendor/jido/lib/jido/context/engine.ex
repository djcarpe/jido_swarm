defmodule Jido.Context.Engine do
  @moduledoc """
  The property-graph engine behind a context graph.

  `Jido.Context.Graph` owns the semantics — upsert, last-writer-wins, topic
  routing — and delegates storage and querying to an engine. The engine
  contract is deliberately small: open a graph, run Cypher against it, dump and
  reload it as JSON Lines.

  ## Implementations

  | Module | Backing |
  |---|---|
  | `Jido.Context.Engine.Glider` | [Glider](https://github.com/agentjido/glider), an embedded property graph. The default. |

  Glider is an optional dependency — it is a Rustler NIF and needs a Rust
  toolchain to build — so `Jido.Context` resolves it at runtime and returns
  `{:error, :engine_unavailable}` with installation instructions when it is
  absent, rather than failing to compile.

  ## Contract notes

  * A handle is opaque and is only ever touched from the owning
    `Jido.Context.Graph` process, so implementations need no internal locking
    beyond whatever the engine itself requires.
  * `run/2` is for statements executed for effect; `query/2` returns rows.
  * `export/1` and `import/2` move a whole graph as JSON Lines. They are the
    snapshot format, so they must round-trip: `import(open(), export(g))`
    reproduces `g`.
  """

  @typedoc "An opaque engine handle."
  @type handle :: term()

  @typedoc """
  Where the graph lives.

  * `:memory` — nothing touches disk.
  * `{:file, path, sync}` — a durable file, with `sync` one of `:always`,
    `:normal` or `:off`.
  """
  @type location :: :memory | {:file, Path.t(), :always | :normal | :off}

  @typedoc "A query result: ordered column names and rows of values."
  @type result :: %{columns: [String.t()], rows: [[term()]]}

  @doc "Opens a graph at `location`."
  @callback open(location()) :: {:ok, handle()} | {:error, term()}

  @doc "Runs a statement for effect, returning the number of entities touched."
  @callback run(handle(), String.t()) :: {:ok, non_neg_integer()} | {:error, term()}

  @doc "Runs a query, returning columns and rows."
  @callback query(handle(), String.t()) :: {:ok, result()} | {:error, term()}

  @doc "Dumps the whole graph as JSON Lines."
  @callback export(handle()) :: {:ok, String.t()} | {:error, term()}

  @doc "Loads JSON Lines produced by `export/1` into the graph."
  @callback import(handle(), String.t()) :: {:ok, term()} | {:error, term()}

  @doc "Flushes buffered writes. A no-op for in-memory graphs."
  @callback checkpoint(handle()) :: :ok | {:error, term()}

  @doc "Node, edge and label counts."
  @callback stats(handle()) :: {:ok, map()} | {:error, term()}

  @doc "Releases the graph and any file lock it holds."
  @callback close(handle()) :: :ok

  @doc "Is this engine usable in the current runtime?"
  @callback available?() :: boolean()

  @doc """
  The default engine.

  Configurable so a test or an alternative backend can replace Glider:

      config :jido, Jido.Context, engine: MyApp.Engine
  """
  @spec default() :: module()
  def default do
    :jido
    |> Application.get_env(Jido.Context, [])
    |> Keyword.get(:engine, Jido.Context.Engine.Glider)
  end
end
