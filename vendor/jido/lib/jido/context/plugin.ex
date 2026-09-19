defmodule Jido.Context.Plugin do
  @moduledoc """
  Gives an agent a context and knowledge graph on a shared mesh.

  Mounting this plugin starts a `Jido.Context.Graph` under the agent's own
  supervision tree and points it at a mesh, so what the agent learns reaches
  its peers and what they learn reaches it.

      defmodule MyApp.Scout do
        use Jido.Agent,
          name: "scout",
          plugins: [
            {Jido.Context.Plugin,
             %{
               graph: :scout_graph,
               mesh: :research_mesh,
               topics: ["knowledge.**"],
               location: :memory,
               store: {:s3, bucket: "agent-graphs", prefix: "research"}
             }}
          ]
      end

  The mesh itself is started once for the application, not per agent:

      children = [
        {Jido.Context.Mesh,
         name: :research_mesh,
         transports: [:pg, {:log, store: {:s3, bucket: "agent-graphs", prefix: "research"}}]},
        {MyApp.Scout, id: "scout"}
      ]

  ## Configuration

  | Key | Meaning |
  |---|---|
  | `:graph` | **required** — the registered name of this agent's graph |
  | `:mesh` | the mesh to join; omit for a private graph |
  | `:topics` | patterns to subscribe to. Default `["**"]` |
  | `:default_topic` | topic for writes that do not name one |
  | `:location` | `:memory` or `{:disk, path: "..."}` |
  | `:store` | snapshot store — `:memory`, `{:disk, ...}`, `{:s3, ...}` |
  | `:origin` | mesh identity. Defaults to `:graph` |
  | `:snapshot_every` / `:snapshot_interval` | when to snapshot |

  Because `:graph` is a registered name, it must be unique per agent instance.
  An agent started many times over — a pod, a worker pool — should give each
  instance its own name and origin.

  ## Actions

  The plugin contributes `context.assert`, `context.relate`, `context.remember`,
  `context.recall` and `context.query`, so an agent can read and write the mesh
  by signal without any custom code.

  ## Why the graph is a child of the agent

  A graph is a process holding a Glider handle and, when it is disk-backed, a
  file lock. Starting it under the agent ties both to the agent's lifetime:
  when the agent stops, the handle is closed and the lock released, and when
  the agent restarts the graph restores from its snapshot.
  """

  use Jido.Plugin,
    name: "context",
    state_key: :__context__,
    actions: [
      Jido.Context.Actions.Assert,
      Jido.Context.Actions.Relate,
      Jido.Context.Actions.Remember,
      Jido.Context.Actions.Recall,
      Jido.Context.Actions.Query
    ],
    description: "Context and knowledge graph shared across agents over a Glider mesh.",
    category: "context",
    tags: ["context", "knowledge", "graph", "mesh"],
    capabilities: [:context, :knowledge_graph]

  alias Jido.Context.Graph

  @impl Jido.Plugin
  def mount(_agent, config) do
    graph = fetch_graph!(config)

    {:ok,
     %{
       graph: graph,
       mesh: Map.get(config, :mesh),
       topics: Map.get(config, :topics, ["**"])
     }}
  end

  @graph_opts [
    :mesh,
    :topics,
    :default_topic,
    :location,
    :store,
    :origin,
    :snapshot_every,
    :snapshot_interval,
    :snapshot_key,
    :restore,
    :engine
  ]

  @impl Jido.Plugin
  def child_spec(config) do
    graph = fetch_graph!(config)

    opts =
      application_defaults()
      |> Keyword.merge(config |> Map.take(@graph_opts) |> Map.to_list())
      |> Keyword.put(:name, graph)

    Graph.child_spec(opts)
  end

  @doc """
  Graph options taken from application config.

  Plugin config is compile-time, which is the wrong place for anything that
  differs between environments — a bucket name, whether graphs live on disk.
  These fill in whatever the plugin config leaves out:

      config :jido, Jido.Context,
        location: {:disk, path: "/var/lib/myapp/graphs"},
        store: {:s3, bucket: "agent-graphs", prefix: "prod"}

  Per-agent plugin config still wins, so one agent can opt out.
  """
  @spec application_defaults() :: keyword()
  def application_defaults do
    :jido
    |> Application.get_env(Jido.Context, [])
    |> Keyword.take(@graph_opts)
  end

  @impl Jido.Plugin
  def signal_routes(_config) do
    [
      {"context.assert", Jido.Context.Actions.Assert},
      {"context.relate", Jido.Context.Actions.Relate},
      {"context.remember", Jido.Context.Actions.Remember},
      {"context.recall", Jido.Context.Actions.Recall},
      {"context.query", Jido.Context.Actions.Query}
    ]
  end

  # The graph name is not derivable from the agent — `child_spec/1` is handed
  # the plugin config and nothing else — so it has to be configured, and a
  # missing one must fail loudly rather than start an unreachable graph.
  defp fetch_graph!(config) do
    case Map.get(config, :graph) do
      name when is_atom(name) and not is_nil(name) ->
        name

      other ->
        raise ArgumentError, """
        Jido.Context.Plugin requires a :graph name, got: #{inspect(other)}

            plugins: [{Jido.Context.Plugin, %{graph: :my_agent_graph, mesh: :my_mesh}}]

        It is the registered name of this agent's graph, so it must be unique
        per running agent.
        """
    end
  end

  @doc """
  The graph name an agent's state is pointing at.

  Actions use this to find the graph without being configured themselves.
  """
  @spec graph(map()) :: atom() | nil
  def graph(agent_state) when is_map(agent_state) do
    get_in(agent_state, [:__context__, :graph])
  end
end
