defmodule JidoSwarm.Application do
  @moduledoc false

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    children =
      [
        JidoSwarmWeb.Telemetry,
        {DNSCluster, query: Application.get_env(:jido_swarm, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: JidoSwarm.PubSub}
      ] ++
        knowledge_children() ++
        [
          # The Jido instance owns the registry and supervision every
          # AgentServer registers into, so it must be up before the pool.
          {Jido, name: JidoSwarm.Jido},
          JidoSwarm.Swarm,
          JidoSwarmWeb.Endpoint
        ]

    opts = [strategy: :one_for_one, name: JidoSwarm.Supervisor]

    with {:ok, pid} <- Supervisor.start_link(children, opts) do
      after_start()
      {:ok, pid}
    end
  end

  # The mesh and the graph only start when the engine is actually present. A
  # deployment missing glider_ex should still serve the UI and say why the graph
  # is unavailable, rather than crashing on boot.
  defp knowledge_children do
    if Jido.Context.available?() do
      [
        {Jido.Context.Mesh, name: JidoSwarm.mesh(), transports: mesh_transports()},
        {Jido.Context.Graph, graph_opts()}
      ]
    else
      Logger.warning("""
      The Glider engine is unavailable, so the swarm has no knowledge graph.
      #{Jido.Context.Engine.Glider.install_hint()}
      """)

      []
    end
  end

  defp graph_opts do
    config = Application.get_env(:jido_swarm, :context, [])

    [
      name: JidoSwarm.graph(),
      origin: origin(),
      mesh: JidoSwarm.mesh(),
      topics: ["knowledge.**", "context.**"],
      default_topic: "knowledge.findings",
      location: Keyword.get(config, :location, :memory),
      store: Keyword.get(config, :store),
      snapshot_every: Keyword.get(config, :snapshot_every, 25)
    ]
  end

  defp mesh_transports do
    config = Application.get_env(:jido_swarm, :context, [])

    case Keyword.get(config, :store) do
      # With an object store configured, run both: `:pg` for pods that share a
      # BEAM cluster, and the topic log so pods that do not still converge.
      nil -> [:pg]
      store -> [:pg, {:log, store: store, interval: 2_000, catch_up: :all}]
    end
  end

  # A stable per-node identity for the mesh. In Kubernetes the pod name is
  # unique and stable for the pod's life, which is exactly the right grain —
  # two pods must never share an origin or their writes tie in the ordering.
  defp origin do
    raw =
      System.get_env("POD_NAME") || System.get_env("HOSTNAME") ||
        to_string(:inet.gethostname() |> elem(1))

    raw
    |> to_string()
    |> String.replace(~r/[^A-Za-z0-9_\-]/, "-")
    |> String.slice(0, 60)
    |> case do
      "" -> "node-" <> (:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower))
      value -> value
    end
  end

  defp after_start do
    if Jido.Context.available?() do
      JidoSwarm.register_repos()
    end

    :ok
  rescue
    e -> Logger.warning("swarm: could not register repositories: #{Exception.message(e)}")
  end

  @impl true
  def config_change(changed, _new, removed) do
    JidoSwarmWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
