defmodule Jido.Context.Mesh.Transport do
  @moduledoc """
  Carries deltas between the graphs in a mesh.

  A mesh runs one or more transports at once, and they compose: the usual
  production shape is `Jido.Context.Mesh.PG` for instant propagation between
  agents that share a BEAM cluster, plus `Jido.Context.Mesh.Log` over S3 so
  that agents which do *not* share a cluster — a different region, a batch job,
  an agent that starts tomorrow — converge as well.

  Duplicate delivery across transports is expected and harmless: a delta is
  identified by `{seq, origin}` and applying it twice is a no-op, and
  `Jido.Context.Mesh` additionally drops ids it has already seen.

  ## Contract

  * `publish/2` hands a delta to the transport. It must not block on remote
    acknowledgement — a slow bucket must not stall the graph that wrote.
  * `child_spec/1` returns a child for the mesh's supervisor, or `nil` when the
    transport needs no process of its own.
  * Inbound deltas are delivered by calling `Jido.Context.Mesh.deliver/2` on the
    mesh named in the transport's options.
  """

  alias Jido.Context.Delta

  @doc "Sends a delta to the rest of the mesh."
  @callback publish(Delta.t(), opts :: keyword()) :: :ok | {:error, term()}

  @doc """
  A child specification for whatever process the transport needs, or `nil`.

  The options carry `:mesh` (the mesh name to deliver into) and `:topics` (the
  patterns this mesh cares about) alongside the transport's own configuration.
  """
  @callback child_spec(opts :: keyword()) :: Supervisor.child_spec() | nil

  @doc """
  Normalizes a transport spec into `{module, opts}`.

      iex> Jido.Context.Mesh.Transport.normalize(:pg)
      {Jido.Context.Mesh.PG, []}

      iex> Jido.Context.Mesh.Transport.normalize({:log, store: :memory})
      {Jido.Context.Mesh.Log, [store: :memory]}
  """
  @spec normalize(term()) :: {module(), keyword()}
  def normalize(:pg), do: {Jido.Context.Mesh.PG, []}
  def normalize({:pg, opts}), do: {Jido.Context.Mesh.PG, opts}
  def normalize({:log, opts}), do: {Jido.Context.Mesh.Log, opts}
  def normalize({mod, opts}) when is_atom(mod) and is_list(opts), do: {mod, opts}
  def normalize(mod) when is_atom(mod), do: {mod, []}
end
