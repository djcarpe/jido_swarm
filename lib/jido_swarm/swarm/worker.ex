defmodule JidoSwarm.Swarm.Worker do
  @moduledoc """
  One member of the swarm: a pull loop wrapped around a Jido agent.

  The worker owns a `Jido.AgentServer` running `JidoSwarm.Swarm.WorkerAgent`,
  announces itself to `JidoSwarm.Swarm.Queue`, and then does one job at a time —
  ask for work, run it through the agent, report, ask again.

  ## Why two processes

  The agent runs the work; this process owns the *pace*. Separating them is
  what makes the pool elastic: a worker is idle or busy as a whole, the queue
  knows which, and the autoscaler can add or retire whole workers without
  reaching inside an agent's mailbox. Pushing jobs straight at agents would
  bury a backlog in individual mailboxes where nothing can see it.

  A job runs in a `Task` rather than in this process's own `handle_info`, so a
  long model call does not make the worker unresponsive to a shutdown request.
  """

  use GenServer, restart: :transient

  require Logger

  alias Jido.AgentServer
  alias Jido.Signal
  alias JidoSwarm.Job
  alias JidoSwarm.Swarm.Queue

  defmodule State do
    @moduledoc false
    @type t :: %__MODULE__{}
    defstruct [:id, :agent_pid, :task, :job, jobs_run: 0]
  end

  @doc false
  def start_link(opts) do
    id = Keyword.fetch!(opts, :id)
    GenServer.start_link(__MODULE__, opts, name: via(id))
  end

  @doc false
  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.fetch!(opts, :id)},
      start: {__MODULE__, :start_link, [opts]},
      restart: :transient,
      shutdown: 30_000
    }
  end

  @doc "The registry tuple for a worker id."
  @spec via(String.t()) :: {:via, Registry, {module(), String.t()}}
  def via(id), do: {:via, Registry, {JidoSwarm.Swarm.Registry, id}}

  @doc "Asks a worker to finish its current job and stop."
  @spec retire(String.t()) :: :ok
  def retire(id) do
    case Registry.lookup(JidoSwarm.Swarm.Registry, id) do
      [{pid, _}] -> GenServer.cast(pid, :retire)
      [] -> :ok
    end
  end

  # ===========================================================================
  # Server
  # ===========================================================================

  @impl true
  def init(opts) do
    id = Keyword.fetch!(opts, :id)
    Process.flag(:trap_exit, true)

    case AgentServer.start_link(
           agent: JidoSwarm.Swarm.WorkerAgent,
           id: id,
           jido: JidoSwarm.Jido
         ) do
      {:ok, agent_pid} ->
        hive(fn ->
          JidoSwarm.Hive.join(
            id: id,
            name: id,
            kind: "worker",
            skills: worker_skills(),
            model: model()
          )
        end)

        send(self(), :pull)
        {:ok, %State{id: id, agent_pid: agent_pid}}

      {:error, reason} ->
        {:stop, {:agent_start_failed, reason}}
    end
  end

  @impl true
  def handle_info(:pull, %State{task: nil} = state) do
    case Queue.ready(state.id, self()) do
      {:job, job} -> {:noreply, start_job(state, job)}
      :idle -> {:noreply, from_hive(state)}
    end
  end

  def handle_info(:pull, state), do: {:noreply, state}

  # Dispatched directly by the queue because this worker was registered idle.
  def handle_info({:swarm_job, job}, %State{task: nil} = state) do
    {:noreply, start_job(state, job)}
  end

  def handle_info({:swarm_job, job}, state) do
    # Should not happen — the queue only pushes to idle workers — but losing a
    # job silently would be worse than a requeue.
    Logger.warning("worker #{state.id} was pushed a job while busy; requeueing #{job.id}")
    Queue.enqueue(job)
    {:noreply, state}
  end

  def handle_info({ref, outcome}, %State{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    finish(state, outcome)
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %State{task: %Task{ref: ref}} = state) do
    finish(state, {:error, {:crashed, reason}})
  end

  def handle_info({:EXIT, pid, reason}, %State{agent_pid: pid} = state) do
    {:stop, {:agent_exited, reason}, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def handle_cast(:retire, %State{task: nil} = state), do: {:stop, :normal, state}

  # Mid-job: let it finish. `finish/2` stops instead of pulling again.
  def handle_cast(:retire, state), do: {:noreply, %{state | job: mark_retiring(state.job)}}

  @impl true
  def terminate(_reason, state) do
    if state.id do
      Queue.leave(state.id)
      hive(fn -> JidoSwarm.Hive.leave(state.id) end)
    end

    :ok
  end

  # ===========================================================================
  # The Hive
  # ===========================================================================

  # Nothing queued: pick a task off the shared board, as any Hive member would.
  # With nothing there either, look again later — the board changes without
  # anyone telling this worker, which is the point of it.
  defp from_hive(state) do
    case hive(fn -> JidoSwarm.Hive.next_task(state.id) end) do
      {:ok, %{task: task, context: context}} ->
        job =
          Queue.busy(
            state.id,
            Job.new(:hive, payload: %{task: task.key, title: task.title, context: context})
          )

        start_job(state, job)

      _ ->
        Process.send_after(self(), :pull, Application.get_env(:jido_swarm, :hive_poll_ms, 5_000))
        state
    end
  end

  # The Hive needs the graph; a node without the engine still runs queued work.
  defp hive(fun) do
    if Process.whereis(Jido.Context.Graph.process_name(JidoSwarm.Hive.Store.graph())) do
      fun.()
    else
      :unavailable
    end
  rescue
    e ->
      Logger.warning("hive unavailable: #{Exception.message(e)}")
      :unavailable
  catch
    :exit, _ -> :unavailable
  end

  defp worker_skills,
    do: Application.get_env(:jido_swarm, :worker_skills, ~w(elixir research design writing))

  # What the Hive shows next to this worker: the active provider's model,
  # whichever provider that is.
  defp model do
    case JidoSwarm.LLM.active_model() do
      nil -> ""
      m -> to_string(m)
    end
  rescue
    _ -> ""
  end

  # ===========================================================================
  # Running a job
  # ===========================================================================

  defp start_job(state, job) do
    worker = state.id
    agent_pid = state.agent_pid

    task =
      Task.async(fn ->
        run(agent_pid, worker, job)
      end)

    %{state | task: task, job: job}
  end

  defp run(agent_pid, worker, job) do
    signal = signal_for(job, worker)

    case AgentServer.call(agent_pid, signal, job_timeout(job)) do
      {:ok, agent} ->
        interpret(job, agent.state)

      {:error, reason} ->
        reply(job, {:error, reason})
        {:error, reason}
    end
  catch
    :exit, reason ->
      reply(job, {:error, {:exit, reason}})
      {:error, {:exit, reason}}
  end

  defp finish(state, outcome) do
    Queue.complete(state.id, state.job, normalize(outcome))
    state = %{state | task: nil, jobs_run: state.jobs_run + 1}

    if retiring?(state.job) do
      {:stop, :normal, %{state | job: nil}}
    else
      send(self(), :pull)
      {:noreply, %{state | job: nil}}
    end
  end

  # A failed instruction still returns `{:ok, agent}` with nothing merged, so
  # success is judged by whether *this* job's result is the one in agent state.
  # See `JidoSwarm.Actions.outcome/2`.
  defp interpret(job, %{job_id: job_id, outcome: :ok} = state) when job_id == job.id do
    reply(job, {:ok, state})
    :ok
  end

  defp interpret(job, %{job_id: job_id, outcome: :error, error: error}) when job_id == job.id do
    reply(job, {:error, error})
    {:error, error}
  end

  defp interpret(job, _state) do
    reply(job, {:error, :no_result})
    {:error, :no_result}
  end

  defp normalize(:ok), do: :ok
  defp normalize({:error, reason}), do: {:error, reason}
  defp normalize(other), do: {:error, other}

  defp signal_for(%Job{type: :survey} = job, worker) do
    signal("swarm.survey", %{repo: job.repo, worker: worker, job_id: job.id})
  end

  defp signal_for(%Job{type: :propose} = job, worker) do
    signal("swarm.propose", %{repo: job.repo, worker: worker, job_id: job.id})
  end

  defp signal_for(%Job{type: :implement} = job, worker) do
    signal("swarm.implement", %{proposal_key: job.proposal_key, worker: worker, job_id: job.id})
  end

  defp signal_for(%Job{type: :chat} = job, worker) do
    signal("swarm.chat", with_model(%{prompt: job.prompt, worker: worker, job_id: job.id}, job))
  end

  defp signal_for(%Job{type: :hive, payload: p} = job, worker) do
    signal(
      "swarm.hive",
      with_model(%{task: p.task, context: p[:context] || "", worker: worker, job_id: job.id}, job)
    )
  end

  defp signal(type, data), do: Signal.new!(type, data, source: "/swarm/worker")

  # Only a job that names a model says so; the action's schema fills the rest.
  defp with_model(data, %Job{model: model}) when is_binary(model) and model != "",
    do: Map.put(data, :model, model)

  defp with_model(data, _job), do: data

  # Implementation runs a full test suite; the others are one model call.
  defp job_timeout(%Job{type: :implement}), do: 900_000
  defp job_timeout(%Job{type: :hive}), do: 600_000
  defp job_timeout(_), do: 300_000

  defp reply(%Job{reply_to: pid, id: id}, result) when is_pid(pid) do
    send(pid, {:swarm_reply, id, result})
  end

  defp reply(_job, _result), do: :ok

  defp mark_retiring(nil), do: nil
  defp mark_retiring(job), do: %{job | payload: Map.put(job.payload, :retiring, true)}

  defp retiring?(%Job{payload: %{retiring: true}}), do: true
  defp retiring?(_), do: false
end
