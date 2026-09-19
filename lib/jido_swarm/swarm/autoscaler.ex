defmodule JidoSwarm.Swarm.Autoscaler do
  @moduledoc """
  Makes the swarm elastic: adds workers when work is waiting, retires them when
  it is not.

  ## The policy

  On every tick it reads the queue and compares pending work to spare capacity.

  * **Scale out** when jobs are pending and every worker is busy, by
    `:scale_step` at a time, up to `:max_workers`. Growth is stepwise rather
    than jumping straight to the backlog size — each worker holds a model
    connection, and a burst of twenty jobs against a 4B local model does not go
    faster for having twenty workers fighting over one GPU.
  * **Scale in** when workers have been idle for `:idle_ttl` with nothing
    pending, down to `:min_workers`. Retirement is graceful: a worker asked to
    retire finishes its current job first.

  The idle timer is what stops it oscillating. Without it a queue that empties
  for one tick would retire workers that are about to be needed again, and the
  cost of a cold worker is an agent start plus a fresh model connection.

  ## Configuration

      config :jido_swarm, JidoSwarm.Swarm.Autoscaler,
        min_workers: 1,
        max_workers: 8,
        scale_step: 2,
        interval: 2_000,
        idle_ttl: 30_000
  """

  use GenServer

  require Logger

  alias JidoSwarm.Swarm
  alias JidoSwarm.Swarm.Queue

  @name __MODULE__

  defmodule State do
    @moduledoc false
    @type t :: %__MODULE__{}
    defstruct [:config, idle_since: nil, last_scale: nil]
  end

  @doc false
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: @name)

  @doc "The current policy."
  @spec config() :: map()
  def config, do: GenServer.call(@name, :config)

  @doc "Runs one scaling decision immediately and returns what it did."
  @spec tick() :: map()
  def tick, do: GenServer.call(@name, :tick)

  @impl true
  def init(opts) do
    config = build_config(opts)
    # Bring the floor up before any work arrives, so the first job does not pay
    # for a cold start.
    ensure_minimum(config)
    schedule(config)
    {:ok, %State{config: config}}
  end

  @impl true
  def handle_call(:config, _from, state), do: {:reply, state.config, state}

  def handle_call(:tick, _from, state) do
    {decision, state} = decide(state)
    {:reply, decision, state}
  end

  @impl true
  def handle_info(:tick, state) do
    {_decision, state} = decide(state)
    schedule(state.config)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ===========================================================================
  # Policy
  # ===========================================================================

  defp decide(state) do
    stats = Queue.stats()
    config = state.config
    now = System.monotonic_time(:millisecond)

    cond do
      # Below the floor — something died, or we just started.
      stats.workers < config.min_workers ->
        started = start_workers(config.min_workers - stats.workers)
        {%{action: :scale_out, started: started, reason: :below_minimum}, %{state | idle_since: nil}}

      # Work is queued and nobody is free to take it.
      stats.pending > 0 and stats.idle == 0 and stats.workers < config.max_workers ->
        want = min(config.scale_step, config.max_workers - stats.workers)
        started = start_workers(want)

        Logger.info(
          "swarm: scaling out by #{started} (#{stats.pending} pending, #{stats.workers} workers)"
        )

        {%{action: :scale_out, started: started, reason: :backlog}, %{state | idle_since: nil}}

      # Nothing to do and spare capacity: start (or continue) the idle timer.
      stats.pending == 0 and stats.idle > 0 and stats.workers > config.min_workers ->
        idle_since = state.idle_since || now

        if now - idle_since >= config.idle_ttl do
          retired = retire_workers(min(stats.idle, stats.workers - config.min_workers))

          Logger.info("swarm: scaling in by #{retired} after #{config.idle_ttl}ms idle")

          {%{action: :scale_in, retired: retired, reason: :idle}, %{state | idle_since: nil}}
        else
          {%{action: :hold, reason: :idle_timer, for: now - idle_since},
           %{state | idle_since: idle_since}}
        end

      true ->
        {%{action: :hold, reason: :balanced}, %{state | idle_since: nil}}
    end
  end

  defp ensure_minimum(config) do
    stats = Queue.stats()

    if stats.workers < config.min_workers do
      start_workers(config.min_workers - stats.workers)
    end
  end

  defp start_workers(count) when count > 0 do
    Enum.count(1..count, fn _ ->
      match?({:ok, _}, Swarm.start_worker())
    end)
  end

  defp start_workers(_), do: 0

  defp retire_workers(count) when count > 0 do
    ids = Queue.idle_worker_ids() |> Enum.take(count)
    Enum.each(ids, &JidoSwarm.Swarm.Worker.retire/1)
    length(ids)
  end

  defp retire_workers(_), do: 0

  defp schedule(config), do: Process.send_after(self(), :tick, config.interval)

  defp build_config(opts) do
    configured = Application.get_env(:jido_swarm, __MODULE__, [])
    merged = Keyword.merge(configured, opts)

    %{
      min_workers: Keyword.get(merged, :min_workers, 1),
      max_workers: Keyword.get(merged, :max_workers, 8),
      scale_step: Keyword.get(merged, :scale_step, 2),
      interval: Keyword.get(merged, :interval, 2_000),
      idle_ttl: Keyword.get(merged, :idle_ttl, 30_000)
    }
  end
end
