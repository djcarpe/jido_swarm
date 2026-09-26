defmodule JidoSwarm.Swarm do
  @moduledoc """
  The elastic pool of Jido agents, and the API for putting work into it.

  ## Shape

      Swarm.Supervisor
        ├── Registry            worker id → pid
        ├── Queue               pending work, dispatch, history
        ├── WorkerSupervisor    DynamicSupervisor over workers
        └── Autoscaler          adds and retires workers

  Workers come and go; the queue and the autoscaler do not. A worker that
  crashes is simply gone — `restart: :transient` on the worker means the
  DynamicSupervisor does not resurrect it, and the autoscaler notices the pool
  is under its floor on the next tick and starts a fresh one. That is cheaper
  and less surprising than restarting a worker whose agent may be in a state
  that caused the crash.
  """

  use Supervisor

  alias JidoSwarm.Job
  alias JidoSwarm.Swarm.Queue
  alias JidoSwarm.Swarm.Worker

  @registry JidoSwarm.Swarm.Registry
  @worker_supervisor JidoSwarm.Swarm.WorkerSupervisor

  @doc false
  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    children = [
      {Registry, keys: :unique, name: @registry},
      {Queue, []},
      {DynamicSupervisor, strategy: :one_for_one, name: @worker_supervisor},
      {JidoSwarm.Swarm.Autoscaler, Keyword.get(opts, :autoscaler, [])}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  # ===========================================================================
  # Submitting work
  # ===========================================================================

  @doc """
  Queues a survey of a repository.
  """
  @spec survey(String.t()) :: {:ok, Job.t()}
  def survey(repo), do: Queue.enqueue(Job.new(:survey, repo: repo))

  @doc "Queues a proposal for a repository."
  @spec propose(String.t()) :: {:ok, Job.t()}
  def propose(repo), do: Queue.enqueue(Job.new(:propose, repo: repo))

  @doc "Queues an implementation of a proposal."
  @spec implement(String.t()) :: {:ok, Job.t()}
  def implement(proposal_key), do: Queue.enqueue(Job.new(:implement, proposal_key: proposal_key))

  @doc """
  Queues a chat turn, replying to `reply_to` with `{:swarm_reply, job_id, result}`.
  """
  @spec chat(String.t(), pid()) :: {:ok, Job.t()}
  def chat(prompt, reply_to \\ self()) do
    Queue.enqueue(Job.new(:chat, prompt: prompt, reply_to: reply_to))
  end

  @doc """
  Surveys every configured repository, then proposes from what each survey found.

  The swarm's standing work, and what the "Run a cycle" button does. Only the
  surveys are queued here: each one carries `then: :propose`, so its proposal is
  created when the survey has actually produced findings. Queueing both up front
  would race — a proposal with nothing to reason from just fails.
  """
  @spec run_cycle() :: {:ok, non_neg_integer()}
  def run_cycle do
    jobs =
      Enum.map(JidoSwarm.Repos.all(), fn repo ->
        Job.new(:survey, repo: repo.name, payload: %{then: :propose})
      end)

    Queue.enqueue_all(jobs)
    {:ok, length(jobs)}
  end

  # ===========================================================================
  # Pool
  # ===========================================================================

  @doc "Starts one worker. Called by the autoscaler."
  @spec start_worker() :: {:ok, pid()} | {:error, term()}
  def start_worker do
    id = "worker-" <> (:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower))
    DynamicSupervisor.start_child(@worker_supervisor, {Worker, id: id})
  end

  @doc "Worker ids currently registered."
  @spec worker_ids() :: [String.t()]
  def worker_ids do
    Registry.select(@registry, [{{:"$1", :_, :_}, [], [:"$1"]}])
  end

  @doc "How many workers are running."
  @spec worker_count() :: non_neg_integer()
  def worker_count, do: DynamicSupervisor.count_children(@worker_supervisor).active

  @doc """
  A snapshot for the dashboard: pool, queue, model, and publishing readiness.
  """
  @spec status() :: map()
  def status do
    stats = Queue.stats()

    %{
      queue: stats,
      workers: worker_ids(),
      autoscaler: JidoSwarm.Swarm.Autoscaler.config(),
      history: Queue.history(),
      failures: Queue.recent_failures(),
      providers: JidoSwarm.LLM.providers(),
      can_publish?: JidoSwarm.Repos.can_publish?(),
      publish_hint: JidoSwarm.Repos.publish_hint()
    }
  end
end
