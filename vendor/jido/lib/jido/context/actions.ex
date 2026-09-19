defmodule Jido.Context.Actions do
  @moduledoc """
  Actions contributed by `Jido.Context.Plugin`.

  They let an agent read and write the shared graph by signal, with no custom
  code: route `context.assert` at an agent and the fact lands on the mesh.

  Each action finds its graph from the agent's `:__context__` state, which the
  plugin populates at mount, so the graph name is configured in one place.
  """

  @doc false
  @spec graph!(map()) :: atom()
  def graph!(state) do
    case Jido.Context.Plugin.graph(state) do
      nil ->
        raise ArgumentError,
              "no context graph is mounted on this agent; add Jido.Context.Plugin to its plugins"

      graph ->
        graph
    end
  end
end

defmodule Jido.Context.Actions.Assert do
  @moduledoc """
  Asserts an entity into the shared graph.

      %{key: "paper:attention", labels: ["Paper"], props: %{"year" => 2017}}
  """

  use Jido.Action,
    name: "context_assert",
    description: "Assert an entity into the shared context and knowledge graph",
    schema: [
      key: [type: :string, required: true, doc: "Mesh-wide identity of the entity"],
      labels: [type: {:list, :string}, default: [], doc: "Labels to apply"],
      # NimbleOptions' bare `:map` requires atom keys; graph property keys are
      # binaries, and a signal arriving as JSON carries them that way.
      props: [
        type: {:map, {:or, [:string, :atom]}, :any},
        default: %{},
        doc: "Properties; keys may not start with _"
      ],
      topic: [type: :string, required: false, doc: "Topic to publish on"]
    ]

  @spec run(map(), map()) :: {:ok, map()} | {:error, term()}
  def run(params, ctx) do
    graph = Jido.Context.Actions.graph!(ctx.state)
    opts = if params[:topic], do: [topic: params.topic], else: []

    case Jido.Context.assert(graph, params.key, params.labels, params.props, opts) do
      {:ok, delta} -> {:ok, %{delta_id: delta.id, seq: delta.seq, key: params.key}}
      {:error, reason} -> {:error, reason}
    end
  end
end

defmodule Jido.Context.Actions.Relate do
  @moduledoc """
  Relates two entities in the shared graph.

      %{from: "paper:attention", type: "CITES", to: "paper:seq2seq"}
  """

  use Jido.Action,
    name: "context_relate",
    description: "Relate two entities in the shared context and knowledge graph",
    schema: [
      from: [type: :string, required: true],
      type: [type: :string, required: true, doc: "Relationship type; an identifier"],
      to: [type: :string, required: true],
      props: [type: {:map, {:or, [:string, :atom]}, :any}, default: %{}],
      topic: [type: :string, required: false]
    ]

  @spec run(map(), map()) :: {:ok, map()} | {:error, term()}
  def run(params, ctx) do
    graph = Jido.Context.Actions.graph!(ctx.state)
    opts = if params[:topic], do: [topic: params.topic], else: []

    case Jido.Context.relate(graph, params.from, params.type, params.to, params.props, opts) do
      {:ok, delta} -> {:ok, %{delta_id: delta.id, seq: delta.seq}}
      {:error, reason} -> {:error, reason}
    end
  end
end

defmodule Jido.Context.Actions.Remember do
  @moduledoc """
  Records an observation scoped to a unit of work.

      %{scope: "task:42", name: "budget_remaining", value: 3}
  """

  use Jido.Action,
    name: "context_remember",
    description: "Record an observation scoped to a task, session or conversation",
    schema: [
      scope: [type: :string, required: true],
      name: [type: :string, required: true],
      value: [type: :any, required: true],
      topic: [type: :string, required: false]
    ]

  @spec run(map(), map()) :: {:ok, map()} | {:error, term()}
  def run(params, ctx) do
    graph = Jido.Context.Actions.graph!(ctx.state)
    opts = if params[:topic], do: [topic: params.topic], else: []

    case Jido.Context.remember(graph, params.scope, params.name, params.value, opts) do
      {:ok, delta} -> {:ok, %{delta_id: delta.id, seq: delta.seq}}
      {:error, reason} -> {:error, reason}
    end
  end
end

defmodule Jido.Context.Actions.Recall do
  @moduledoc """
  Reads back everything remembered under a scope.

      %{scope: "task:42"}  #=> %{entries: %{"budget_remaining" => 3}}
  """

  use Jido.Action,
    name: "context_recall",
    description: "Read everything remembered under a scope",
    schema: [
      scope: [type: :string, required: true]
    ]

  @spec run(map(), map()) :: {:ok, map()} | {:error, term()}
  def run(params, ctx) do
    graph = Jido.Context.Actions.graph!(ctx.state)

    case Jido.Context.recall(graph, params.scope) do
      {:ok, entries} -> {:ok, %{scope: params.scope, entries: entries}}
      {:error, reason} -> {:error, reason}
    end
  end
end

defmodule Jido.Context.Actions.Query do
  @moduledoc """
  Runs a Cypher query against the agent's graph.

      %{cypher: "MATCH (p:Paper) RETURN p.title"}

  The query runs against this agent's own replica, so it is a local read — no
  network, no coordination — over whatever the mesh has delivered so far.
  """

  use Jido.Action,
    name: "context_query",
    description: "Run a Cypher query against the agent's context and knowledge graph",
    schema: [
      cypher: [type: :string, required: true]
    ]

  @spec run(map(), map()) :: {:ok, map()} | {:error, term()}
  def run(params, ctx) do
    graph = Jido.Context.Actions.graph!(ctx.state)

    case Jido.Context.query(graph, params.cypher) do
      {:ok, result} -> {:ok, %{columns: result.columns, rows: result.rows}}
      {:error, reason} -> {:error, reason}
    end
  end
end
