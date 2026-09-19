defmodule Jido.Context.Store.Memory do
  @moduledoc """
  An in-memory `Jido.Context.Store`, backed by one ETS table.

  Nothing survives the VM. This is the default store: a graph configured with
  `store: :memory` keeps its snapshot in RAM, which is useful for tests and for
  meshes whose knowledge is genuinely ephemeral.

  Because the table is public and named, several graphs share it and agents in
  one VM can stream deltas through it — which is what
  `Jido.Context.Mesh.Store` uses when a mesh is configured for a single node.

  The table is created on first use, owned by `Jido.Storage.ETS.Owner` so that
  it outlives any individual graph process.
  """

  @behaviour Jido.Context.Store

  @table :jido_context_store_memory

  @table_opts [:ordered_set, :public, :named_table, read_concurrency: true]

  @doc """
  Ensures the backing table exists.

  Safe to call from anywhere and any number of times. The table is created
  inside `Jido.Storage.ETS.Owner`, so it outlives any individual graph — a
  crashing graph must not take the mesh's in-memory transport with it.

  If the owner is not running, the caller creates the table itself. That keeps
  the store usable in a bare test or script, at the cost of the table dying
  with whoever made it.
  """
  @spec ensure_table() :: :ok
  def ensure_table do
    case :ets.whereis(@table) do
      :undefined -> create_table()
      _ref -> :ok
    end
  end

  defp create_table do
    case Jido.Storage.ETS.Owner.create_table(@table, @table_opts) do
      :ok -> :ok
      {:error, _not_started} -> create_locally()
    end
  end

  defp create_locally do
    :ets.new(@table, @table_opts)
    :ok
  rescue
    # Another process created it between `whereis` and `new`.
    ArgumentError -> :ok
  end

  @impl true
  def get(key, _opts) do
    ensure_table()

    case :ets.lookup(@table, key) do
      [{^key, body}] -> {:ok, body}
      [] -> :not_found
    end
  end

  @impl true
  def put(key, body, _opts) when is_binary(key) and is_binary(body) do
    ensure_table()
    :ets.insert(@table, {key, body})
    :ok
  end

  @impl true
  def delete(key, _opts) do
    ensure_table()
    :ets.delete(@table, key)
    :ok
  end

  @impl true
  def list(prefix, opts) do
    ensure_table()

    after_key = opts[:after]
    limit = opts[:limit]

    keys =
      @table
      |> :ets.select([{{:"$1", :_}, [], [:"$1"]}])
      |> Enum.filter(&String.starts_with?(&1, prefix))
      |> Enum.filter(fn key -> is_nil(after_key) or key > after_key end)
      |> Enum.sort()

    {:ok, if(limit, do: Enum.take(keys, limit), else: keys)}
  end

  @doc "Removes every object. For tests."
  @spec reset() :: :ok
  def reset do
    ensure_table()
    :ets.delete_all_objects(@table)
    :ok
  end
end
