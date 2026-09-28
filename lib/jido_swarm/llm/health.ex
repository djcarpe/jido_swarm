defmodule JidoSwarm.LLM.Health do
  @moduledoc """
  Whether each model provider is reachable, checked in the background and
  read from memory.

  The console asks on every mount and every refresh, and `Ollama.ready?/0` is
  an HTTP round trip with a five-second timeout. Asked inline, an unreachable
  server made every page take five seconds to mount — long enough for
  LiveView to give up on the websocket and fall back to long polling, which
  across two pods behind one Service with no session affinity meant a page
  that could never stay connected. Readiness is a fact about the world that
  changes slowly; probing it once every #{div(30_000, 1000)} seconds, off the
  request path, is the honest rate.

  Before the first probe finishes a provider reads as not ready, which is the
  safe answer to show for a few hundred milliseconds after boot.
  """

  use GenServer

  require Logger

  @interval 30_000
  @table :jido_swarm_llm_health

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Is `provider` ready, as of the last probe? False until one has run."
  @spec ready?(module()) :: boolean()
  def ready?(provider) do
    case :ets.lookup(@table, provider) do
      [{^provider, ready?, _at}] -> ready?
      [] -> false
    end
  rescue
    ArgumentError -> false
  end

  @doc "When `provider` was last probed, in ms since the epoch, or nil."
  @spec probed_at(module()) :: integer() | nil
  def probed_at(provider) do
    case :ets.lookup(@table, provider) do
      [{^provider, _ready?, at}] -> at
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @doc "Probes every provider now and waits for the answers. For tests and operators."
  @spec refresh(GenServer.server()) :: :ok
  def refresh(server \\ __MODULE__), do: GenServer.call(server, :refresh, 30_000)

  @impl true
  def init(opts) do
    :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    providers = Keyword.get(opts, :providers, JidoSwarm.LLM.provider_modules())
    interval = Keyword.get(opts, :interval, @interval)
    send(self(), :probe)
    {:ok, %{providers: providers, interval: interval}}
  end

  @impl true
  def handle_call(:refresh, _from, state) do
    probe(state.providers)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:probe, state) do
    probe(state.providers)
    Process.send_after(self(), :probe, state.interval)
    {:noreply, state}
  end

  # Providers are probed side by side, so one that hangs does not delay the
  # others; each answer lands in the table as it arrives.
  defp probe(providers) do
    providers
    |> Task.async_stream(
      fn mod -> {mod, safe_ready?(mod)} end,
      timeout: 15_000,
      on_timeout: :kill_task,
      ordered: false
    )
    |> Enum.each(fn
      {:ok, {mod, ready?}} -> :ets.insert(@table, {mod, ready?, System.system_time(:millisecond)})
      {:exit, _} -> :ok
    end)
  end

  defp safe_ready?(mod) do
    mod.ready?()
  rescue
    e ->
      Logger.debug("llm health: #{inspect(mod)} readiness raised #{Exception.message(e)}")
      false
  end
end
