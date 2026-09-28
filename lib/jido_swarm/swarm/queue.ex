defmodule JidoSwarm.Swarm.Queue do
  @moduledoc """
  The swarm's work queue and dispatcher.

  Pull-based: a worker announces it is ready, and the queue either hands it a
  job or records it as idle. When a job arrives, the queue dispatches it to an
  idle worker if there is one. Nothing is pushed at a busy worker, so a slow
  model call cannot build a backlog inside one worker's mailbox — the backlog
  stays here, where the autoscaler can see it and add capacity.

  That visibility is the whole reason the queue owns dispatch rather than, say,
  a `Registry` round-robin: depth here is the signal `JidoSwarm.Swarm.Autoscaler`
  scales on.

  Broadcasts `{:swarm_event, event}` on the `"swarm"` PubSub topic for the UI.
  """

  use GenServer

  require Logger

  alias JidoSwarm.Job

  @name __MODULE__
  @history_limit 50

  defmodule State do
    @moduledoc false
    @type t :: %__MODULE__{}
    defstruct pending: :queue.new(),
              pending_count: 0,
              idle: [],
              busy: %{},
              history: [],
              completed: 0,
              failed: 0
  end

  # ===========================================================================
  # API
  # ===========================================================================

  @doc false
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: @name)

  @doc """
  Enqueues a job, dispatching it immediately if a worker is idle.
  """
  @spec enqueue(Job.t()) :: {:ok, Job.t()}
  def enqueue(%Job{} = job), do: GenServer.call(@name, {:enqueue, job})

  @doc "Enqueues several jobs at once."
  @spec enqueue_all([Job.t()]) :: :ok
  def enqueue_all(jobs), do: Enum.each(jobs, &enqueue/1)

  @doc """
  Announces a worker as ready for work.

  Returns `{:job, job}` when there is work waiting, or `:idle` when there is
  not — in which case the worker will be sent `{:swarm_job, job}` once a job
  arrives.
  """
  @spec ready(String.t(), pid()) :: {:job, Job.t()} | :idle
  def ready(worker_id, pid \\ self()), do: GenServer.call(@name, {:ready, worker_id, pid})

  @doc """
  Marks an idle worker busy with a job it found itself (a Hive task), so the
  queue does not dispatch to it and the dashboard shows what it is doing.
  Returns the job as running.
  """
  @spec busy(String.t(), Job.t()) :: Job.t()
  def busy(worker_id, %Job{} = job), do: GenServer.call(@name, {:busy, worker_id, job})

  @doc "Reports a finished job."
  @spec complete(String.t(), Job.t(), :ok | {:error, term()}) :: :ok
  def complete(worker_id, %Job{} = job, outcome),
    do: GenServer.cast(@name, {:complete, worker_id, job, outcome})

  @doc "Removes a worker from the pool — it is shutting down."
  @spec leave(String.t()) :: :ok
  def leave(worker_id), do: GenServer.cast(@name, {:leave, worker_id})

  @doc """
  A snapshot of queue state, for the autoscaler and the dashboard.
  """
  @spec stats() :: map()
  def stats, do: GenServer.call(@name, :stats)

  @doc "Recently finished jobs, newest first."
  @spec history() :: [map()]
  def history, do: GenServer.call(@name, :history)

  @doc """
  The most recent distinct failure reasons, newest first.

  A swarm whose every job fails for one reason is the common case — a missing
  credential, an unreachable model — and it is far more useful to say that once,
  loudly, than to list forty identical rows in a history nobody scrolls to.
  """
  @spec recent_failures(pos_integer()) :: [map()]
  def recent_failures(limit \\ 3), do: GenServer.call(@name, {:recent_failures, limit})

  @doc """
  The ids of workers currently idle.

  The autoscaler retires from this list: a worker that is not holding a job can
  be stopped without waiting for anything.
  """
  @spec idle_worker_ids() :: [String.t()]
  def idle_worker_ids, do: GenServer.call(@name, :idle_worker_ids)

  # ===========================================================================
  # Server
  # ===========================================================================

  @impl true
  def init(_opts), do: {:ok, %State{}}

  @impl true
  def handle_call({:enqueue, job}, _from, state) do
    {:reply, {:ok, job}, do_enqueue(state, job)}
  end

  def handle_call({:ready, worker_id, pid}, _from, state) do
    state = %{state | busy: Map.delete(state.busy, worker_id)}

    case :queue.out(state.pending) do
      {{:value, job}, rest} ->
        started = running(job, worker_id)

        state = %{
          state
          | pending: rest,
            pending_count: state.pending_count - 1,
            busy: Map.put(state.busy, worker_id, started)
        }

        {:reply, {:job, started}, state}

      {:empty, _} ->
        idle = List.keystore(state.idle, worker_id, 0, {worker_id, pid})
        {:reply, :idle, %{state | idle: idle}}
    end
  end

  def handle_call({:busy, worker_id, job}, _from, state) do
    started = running(job, worker_id)

    {:reply, started,
     %{
       state
       | idle: List.keydelete(state.idle, worker_id, 0),
         busy: Map.put(state.busy, worker_id, started)
     }}
  end

  def handle_call(:stats, _from, state) do
    {:reply,
     %{
       pending: state.pending_count,
       idle: length(state.idle),
       busy: map_size(state.busy),
       workers: length(state.idle) + map_size(state.busy),
       completed: state.completed,
       failed: state.failed,
       running: Map.values(state.busy)
     }, state}
  end

  def handle_call(:history, _from, state), do: {:reply, state.history, state}

  def handle_call({:recent_failures, limit}, _from, state) do
    failures =
      state.history
      |> Enum.filter(&(&1.status == :failed and &1.error not in [nil, ""]))
      |> Enum.uniq_by(& &1.error)
      |> Enum.take(limit)

    {:reply, failures, state}
  end

  def handle_call(:idle_worker_ids, _from, state) do
    {:reply, Enum.map(state.idle, &elem(&1, 0)), state}
  end

  @impl true
  def handle_cast({:complete, worker_id, job, outcome}, state) do
    finished = %{
      job
      | status: if(outcome == :ok, do: :done, else: :failed),
        error: if(outcome == :ok, do: nil, else: elem(outcome, 1)),
        worker: worker_id,
        finished_at: System.system_time(:millisecond)
    }

    state = %{
      state
      | busy: Map.delete(state.busy, worker_id),
        history: Enum.take([summarize(finished) | state.history], @history_limit),
        completed: state.completed + if(outcome == :ok, do: 1, else: 0),
        failed: state.failed + if(outcome == :ok, do: 0, else: 1)
    }

    if outcome != :ok do
      Logger.warning("swarm job #{job.id} (#{job.type}) failed: #{inspect(elem(outcome, 1))}")
    end

    broadcast({:completed, finished})
    {:noreply, maybe_chain(state, finished, outcome)}
  end

  def handle_cast({:leave, worker_id}, state) do
    {:noreply,
     %{
       state
       | idle: List.keydelete(state.idle, worker_id, 0),
         busy: Map.delete(state.busy, worker_id)
     }}
  end

  # Dispatch to an idle worker if there is one, otherwise hold the job. Shared
  # by the public enqueue and by chaining, which must not `GenServer.call` this
  # process from inside its own callback.
  defp do_enqueue(state, job) do
    state =
      case state.idle do
        [{worker_id, pid} | rest] ->
          # The worker is handed the *stamped* job so the started_at it reports
          # back is the one the queue recorded — otherwise every duration is nil.
          started = running(job, worker_id)
          send(pid, {:swarm_job, started})

          %{state | idle: rest, busy: Map.put(state.busy, worker_id, started)}

        [] ->
          %{
            state
            | pending: :queue.in(job, state.pending),
              pending_count: state.pending_count + 1
          }
      end

    broadcast({:enqueued, job})
    state
  end

  # Some work only makes sense after other work succeeded — a proposal needs
  # findings to follow from. Chaining here rather than enqueueing both up front
  # is what keeps `run_cycle` from racing itself: the follow-up is created when
  # its precondition is a fact, not a hope.
  defp maybe_chain(state, %Job{payload: %{then: next}} = job, :ok) when is_atom(next) do
    do_enqueue(state, Job.new(next, repo: job.repo, proposal_key: job.proposal_key))
  end

  defp maybe_chain(state, _job, _outcome), do: state

  # A worker that dies mid-job takes its job with it. Requeueing here would risk
  # replaying a half-finished side effect (a branch pushed, a PR opened), so the
  # job is recorded as failed and left for the operator to retry deliberately.
  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:noreply, state}
  def handle_info(_msg, state), do: {:noreply, state}

  defp running(job, worker_id) do
    %{job | status: :running, worker: worker_id, started_at: System.system_time(:millisecond)}
  end

  defp summarize(job) do
    %{
      id: job.id,
      type: job.type,
      label: Job.label(job),
      status: job.status,
      worker: job.worker,
      error: job.error && inspect(job.error),
      duration_ms: duration(job)
    }
  end

  defp duration(%{started_at: nil}), do: nil
  defp duration(%{started_at: s, finished_at: f}) when is_integer(f), do: f - s
  defp duration(_), do: nil

  defp broadcast(event) do
    Phoenix.PubSub.broadcast(JidoSwarm.PubSub, "swarm", {:swarm_event, event})
  end
end
