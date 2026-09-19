defmodule Jido.Context.Store do
  @moduledoc """
  Where a context graph's durable artifacts live.

  A store holds two kinds of object, both plain blobs:

  * **Snapshots** — the whole graph, as JSON Lines from `Jido.Context.Engine.export/1`.
    A snapshot is how a graph boots with what the mesh already knew.
  * **Topic log entries** — individual deltas, written under a topic prefix so
    that agents on other nodes can stream them. See `Jido.Context.Mesh.S3`.

  Both are just keys and bytes, so one behaviour covers them.

  ## Adapters

  | Adapter | Durability | Shared across nodes |
  |---|---|---|
  | `Jido.Context.Store.Memory` | none — dies with the VM | no |
  | `Jido.Context.Store.Disk` | survives a restart | only via a shared filesystem |
  | `Jido.Context.Store.S3` | object storage | yes |

  ## Configuration

  Stores are named by a `{module, opts}` tuple, or by a shorthand atom that
  `normalize/1` expands:

      store: :memory
      store: {:disk, path: "priv/jido/context"}
      store: {:s3, bucket: "graphs", prefix: "mesh", region: "us-east-1"}

  ## Listing

  `list/2` is what makes streaming work: a poller asks for the keys under a
  topic prefix that sort after the last one it saw. Keys are therefore required
  to sort lexicographically in the order they were written, which is why
  `Jido.Context.Mesh.S3` zero-pads sequence numbers into them.
  """

  @type opts :: keyword()

  @doc "Reads an object. `:not_found` when the key does not exist."
  @callback get(key :: String.t(), opts()) :: {:ok, binary()} | :not_found | {:error, term()}

  @doc "Writes an object, overwriting any existing value."
  @callback put(key :: String.t(), body :: binary(), opts()) :: :ok | {:error, term()}

  @doc "Deletes an object. `:ok` even when it was not there."
  @callback delete(key :: String.t(), opts()) :: :ok | {:error, term()}

  @doc """
  Lists keys under `prefix`, in lexicographic order.

  ## Options

  * `:after` — return only keys strictly greater than this one.
  * `:limit` — cap the number of keys returned.
  """
  @callback list(prefix :: String.t(), opts()) :: {:ok, [String.t()]} | {:error, term()}

  @doc """
  Expands a store shorthand into `{module, opts}`.

      iex> Jido.Context.Store.normalize(:memory)
      {Jido.Context.Store.Memory, []}

      iex> Jido.Context.Store.normalize({:disk, path: "/tmp/ctx"})
      {Jido.Context.Store.Disk, [path: "/tmp/ctx"]}

      iex> Jido.Context.Store.normalize({Jido.Context.Store.Memory, []})
      {Jido.Context.Store.Memory, []}
  """
  @spec normalize(term()) :: {module(), opts()}
  def normalize(:memory), do: {Jido.Context.Store.Memory, []}
  def normalize({:memory, opts}), do: {Jido.Context.Store.Memory, opts}
  def normalize({:disk, opts}), do: {Jido.Context.Store.Disk, opts}
  def normalize({:s3, opts}), do: {Jido.Context.Store.S3, opts}
  def normalize({mod, opts}) when is_atom(mod) and is_list(opts), do: {mod, opts}
  def normalize(mod) when is_atom(mod), do: {mod, []}

  @doc "Reads through a normalized store spec."
  @spec get({module(), opts()}, String.t()) :: {:ok, binary()} | :not_found | {:error, term()}
  def get({mod, opts}, key), do: mod.get(key, opts)

  @doc "Writes through a normalized store spec."
  @spec put({module(), opts()}, String.t(), binary()) :: :ok | {:error, term()}
  def put({mod, opts}, key, body), do: mod.put(key, body, opts)

  @doc "Deletes through a normalized store spec."
  @spec delete({module(), opts()}, String.t()) :: :ok | {:error, term()}
  def delete({mod, opts}, key), do: mod.delete(key, opts)

  @doc "Lists through a normalized store spec."
  @spec list({module(), opts()}, String.t(), opts()) :: {:ok, [String.t()]} | {:error, term()}
  def list({mod, opts}, prefix, list_opts \\ []),
    do: mod.list(prefix, Keyword.merge(opts, list_opts))
end
