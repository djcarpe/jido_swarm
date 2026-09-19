defmodule Jido.Context.Mesh.PG do
  @moduledoc """
  A `Jido.Context.Mesh.Transport` over `:pg`, OTP's process groups.

  Every mesh router with the same name joins one process group. Publishing
  casts the delta straight to the other members — on a single node that is a
  message send, and across a connected BEAM cluster a distributed one. No
  serialisation, no broker, no polling.

  This is the fast path, and it is not the durable one: a delta published while
  a peer is down is simply never seen by that peer. Pair it with
  `Jido.Context.Mesh.Log` when agents must converge on knowledge produced
  before they started.

  `:pg` runs under a Jido-specific scope so this neither depends on nor
  disturbs an application's other process groups.
  """

  use GenServer

  @behaviour Jido.Context.Mesh.Transport

  alias Jido.Context.Delta
  alias Jido.Context.Mesh

  @scope :jido_context_mesh

  @impl Jido.Context.Mesh.Transport
  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.fetch!(opts, :mesh)},
      start: {__MODULE__, :start_link, [opts]},
      type: :worker
    }
  end

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl GenServer
  def init(opts) do
    mesh = Keyword.fetch!(opts, :mesh)
    ensure_scope()

    # Group membership is held by the *router's* pid, not this process: `:pg`
    # monitors its members, so tying membership to the process that actually
    # receives deltas means a dead router leaves the group immediately.
    router = Process.whereis(Mesh.router_name(mesh))

    if is_nil(router) do
      {:stop, {:router_not_running, mesh}}
    else
      :ok = :pg.join(@scope, group(mesh), router)
      {:ok, %{mesh: mesh, router: router}}
    end
  end

  @impl Jido.Context.Mesh.Transport
  def publish(%Delta{} = delta, opts) do
    mesh = Keyword.fetch!(opts, :mesh)
    self_router = Process.whereis(Mesh.router_name(mesh))

    @scope
    |> :pg.get_members(group(mesh))
    |> Enum.reject(&(&1 == self_router))
    |> Enum.each(&GenServer.cast(&1, {:deliver, delta}))

    :ok
  rescue
    # `:pg.get_members/2` raises when the scope has never been started, which
    # happens only if a publish beats this transport's own init.
    ArgumentError -> :ok
  end

  @doc false
  @spec group(atom()) :: {:jido_context, atom()}
  def group(mesh), do: {:jido_context, mesh}

  @doc """
  Starts the shared `:pg` scope if it is not already running.

  The scope is started unlinked and deliberately outlives any one mesh: several
  meshes share it, and tying its lifetime to whichever happened to start first
  would take the others down with it.
  """
  @spec ensure_scope() :: :ok
  def ensure_scope do
    case :pg.start(@scope) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end
end
