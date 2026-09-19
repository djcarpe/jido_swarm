defmodule Jido.Storage.ETS.Owner do
  @moduledoc false

  use GenServer

  @name __MODULE__
  @call_timeout 5_000

  @doc false
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: @name,
      start: {@name, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 5_000
    }
  end

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: @name)
  end

  @doc false
  @spec ensure_tables(keyword()) :: :ok | {:error, term()}
  def ensure_tables(opts) when is_list(opts) do
    case GenServer.whereis(@name) do
      nil -> {:error, :not_started}
      pid -> GenServer.call(pid, {:ensure_tables, opts}, @call_timeout)
    end
  catch
    :exit, reason -> {:error, {:owner_unavailable, reason}}
  end

  @doc """
  Creates a named ETS table owned by this process, if it does not exist.

  Tables are created *inside* the owner rather than handed over with
  `:ets.give_away/3`, so no transfer message is involved and the table's
  lifetime is the owner's from the start.
  """
  @spec create_table(atom(), [term()]) :: :ok | {:error, term()}
  def create_table(name, opts) when is_atom(name) and is_list(opts) do
    case GenServer.whereis(@name) do
      nil -> {:error, :not_started}
      pid -> GenServer.call(pid, {:create_table, name, opts}, @call_timeout)
    end
  catch
    :exit, reason -> {:error, {:owner_unavailable, reason}}
  end

  @impl true
  def init(_opts) do
    {:ok, %{}}
  end

  @impl true
  def handle_call({:ensure_tables, opts}, _from, state) do
    {:reply, Jido.Storage.ETS.create_tables(opts), state}
  end

  def handle_call({:create_table, name, opts}, _from, state) do
    result =
      case :ets.whereis(name) do
        :undefined ->
          :ets.new(name, opts)
          :ok

        _ref ->
          :ok
      end

    {:reply, result, state}
  end
end
