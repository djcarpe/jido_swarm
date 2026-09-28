defmodule JidoSwarm.Application do
  @moduledoc false

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    JidoSwarm.MCP.init()

    children =
      [
        JidoSwarmWeb.Telemetry,
        {DNSCluster, query: Application.get_env(:jido_swarm, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: JidoSwarm.PubSub},
        # Before the graph, so no operation goes unmeasured — including the
        # graph's own startup, which is the slowest one there is.
        JidoSwarm.GliderMetrics
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
      :jido_swarm
      |> Application.get_env(:context, [])
      |> Keyword.get(:location, :memory)
      |> then(fn location ->
        if single_writer?(), do: clear_stale_lock(location)
      end)

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

  # Glider takes a lock file beside the graph so two processes cannot open the
  # same file. In a container that protection inverts into a deadlock: the lock
  # records the holder's pid, every containerised BEAM is pid 1, and the volume
  # outlives the process. So after any hard exit the next start finds a lock
  # "held by pid 1" — itself, one incarnation ago — and refuses forever. Seen
  # in the cluster as 741 restarts of a pod that could never boot again.
  #
  # Clearing it is only safe because of how this is deployed: each pod has its
  # own volume and runs exactly one BEAM, so a lock found at startup can never
  # belong to a living writer. That is a property of the deployment, not of
  # Glider, which is why this is opt-in rather than something the library does.
  defp clear_stale_lock(location) do
    with {:disk, opts} <- location,
         path when is_binary(path) <- Keyword.get(opts, :path),
         lock = path <> ".lock",
         true <- File.exists?(lock) do
      case File.rm(lock) do
        :ok ->
          Logger.warning(
            "swarm: removed a stale graph lock at #{lock}. The previous run exited without " <>
              "releasing it; this pod is the only writer, so the lock cannot be live."
          )

        {:error, reason} ->
          Logger.error("swarm: could not remove the stale graph lock #{lock}: #{inspect(reason)}")
      end
    end

    :ok
  end

  defp graph_opts do
    config = Application.get_env(:jido_swarm, :context, [])

    [
      name: JidoSwarm.graph(),
      origin: origin(),
      mesh: JidoSwarm.mesh(),
      # hive.** carries the self-organising board (JidoSwarm.Hive).
      topics: ["knowledge.**", "context.**", "hive.**"],
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

  # True when this process is the only thing that will ever open the graph file
  # — one BEAM per pod, on a volume nothing else mounts. Set by the Deployment.
  defp single_writer? do
    System.get_env("SWARM_SINGLE_WRITER", "false") in ["1", "true", "yes"]
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
