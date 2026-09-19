defmodule Jido.Context.Mesh do
  @moduledoc """
  Topic-routed delta distribution between context graphs.

  A mesh is the seam between agents. Each agent owns its own
  `Jido.Context.Graph`; the mesh is what makes what one agent learns show up in
  the others' graphs, routed by topic so an agent subscribes to the knowledge it
  cares about rather than all of it.

      {:ok, _} =
        Jido.Context.Mesh.start_link(
          name: :research_mesh,
          transports: [
            :pg,
            {:log, store: {:s3, bucket: "graphs", prefix: "research"}}
          ]
        )

  ## Routing

  Subscribers register topic *patterns*; publishers tag each delta with a
  concrete topic. Patterns are dot-segmented, with `*` for one segment and `**`
  for the remainder — the same shape as Jido signal paths:

      "knowledge.papers"     exactly that topic
      "knowledge.*"          knowledge.papers, not knowledge.papers.nlp
      "knowledge.**"         both
      "**"                   everything

  ## Transports

  A mesh runs any number of transports at once, and they compose:

  | Transport | Reach | Latency |
  |---|---|---|
  | `Jido.Context.Mesh.PG` | agents sharing a BEAM cluster | a message send |
  | `Jido.Context.Mesh.Log` | anything that can read the store | the poll interval |

  The production shape is both: `:pg` so co-located agents see each other
  immediately, and `{:log, store: {:s3, ...}}` so agents elsewhere — another
  region, a batch job, an agent that starts tomorrow — converge too.

  ## Loops and duplicates

  A delta published locally goes out to every transport *and* to local
  subscribers. It will usually come back: the log poller reads the object the
  mesh itself wrote, and a second transport may deliver it again. The router
  keeps a bounded set of recently-seen delta ids and drops repeats, and
  `Jido.Context.Graph` is idempotent besides, so a duplicate that outlives the
  window changes nothing.

  ## Delivery

  Subscribers receive `{:jido_context_delta, mesh_name, delta}`. Delivery is a
  plain message send: the mesh never blocks on a subscriber, and a subscriber
  that dies is dropped when its monitor fires.
  """

  use Supervisor

  alias Jido.Context.Delta
  alias Jido.Context.Mesh.Router
  alias Jido.Context.Mesh.Transport

  @doc """
  Starts a mesh and its transports under one supervisor.

  ## Options

  * `:name` — required. The registered name, and the mesh id in delivery messages.
  * `:transports` — transport specs. Defaults to `[:pg]`.
  * `:topics` — patterns the mesh's polling transports should pull. Defaults to
    `["**"]`.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    Supervisor.start_link(__MODULE__, opts, name: supervisor_name(name))
  end

  @doc false
  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.fetch!(opts, :name)},
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor
    }
  end

  @impl true
  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    topics = Keyword.get(opts, :topics, ["**"])

    # `:mesh` and `:topics` are merged in once, here, so the router and the
    # transport's own process are handed identical options — `publish/2` runs in
    # the router and needs to know which mesh it is publishing for.
    transports =
      opts
      |> Keyword.get(:transports, [:pg])
      |> Enum.map(&Transport.normalize/1)
      |> Enum.map(fn {mod, transport_opts} ->
        {mod, Keyword.merge(transport_opts, mesh: name, topics: topics)}
      end)

    router = {Router, name: name, transports: transports}

    # A transport that needs no process of its own returns nil.
    transport_children =
      for {mod, transport_opts} <- transports,
          spec = mod.child_spec(transport_opts),
          not is_nil(spec),
          do: spec

    Supervisor.init([router | transport_children], strategy: :one_for_one)
  end

  @doc false
  @spec router_name(atom()) :: atom()
  def router_name(name), do: :"#{name}.Router"

  @doc false
  @spec supervisor_name(atom()) :: atom()
  def supervisor_name(name), do: :"#{name}.Supervisor"

  @doc """
  Subscribes the calling process to topic patterns.

  The subscriber receives `{:jido_context_delta, mesh_name, delta}` for every
  matching delta, whether it originated locally or arrived over a transport.
  """
  @spec subscribe(atom(), [String.t()]) :: :ok
  def subscribe(mesh, patterns) when is_list(patterns) do
    GenServer.call(router_name(mesh), {:subscribe, self(), patterns})
  end

  @doc "Stops delivering to the calling process."
  @spec unsubscribe(atom()) :: :ok
  def unsubscribe(mesh) do
    GenServer.call(router_name(mesh), {:unsubscribe, self()})
  end

  @doc "Publishes a delta to local subscribers and out through every transport."
  @spec publish(atom(), Delta.t()) :: :ok
  def publish(mesh, %Delta{} = delta) do
    GenServer.cast(router_name(mesh), {:publish, delta})
  end

  @doc """
  Delivers an inbound delta to local subscribers only, without re-publishing.

  Transports call this. Application code calls `publish/2` instead — sending an
  inbound delta back out is how two transports end up trading it forever.
  """
  @spec deliver(atom(), Delta.t()) :: :ok
  def deliver(mesh, %Delta{} = delta) do
    GenServer.cast(router_name(mesh), {:deliver, delta})
  end

  @doc "Is a mesh with this name running?"
  @spec alive?(atom()) :: boolean()
  def alive?(mesh), do: is_pid(Process.whereis(router_name(mesh)))

  @doc """
  Blocks until every delta published so far has been fanned out.

  A publish is a cast, so a test that publishes and immediately asserts would
  race the router. This is a synchronous call behind the same mailbox, so it
  returns only once the queue ahead of it has drained.
  """
  @spec sync(atom(), timeout()) :: :ok
  def sync(mesh, timeout \\ 5_000) do
    GenServer.call(router_name(mesh), :sync, timeout)
  end
end
