defmodule JidoSwarm.Hive.Claims do
  @moduledoc """
  Who holds which task: leases over the shared graph, without a lock server.

  A task's lifecycle lives in one entity, `claim:<task>`, carrying the holder,
  a lease deadline, the state and an attempt count. `Jido.Context` resolves
  concurrent writes to one entity by last-writer-wins on a total order, so when
  two agents claim the same task at once **every replica converges on the same
  winner**. That makes a claim a two-step protocol:

  1. **claim** — only if the task is open (unclaimed, released, or its lease
     expired), write `claim:<task>` naming yourself;
  2. **verify** — after the mesh has had a moment to deliver concurrent claims,
     read it back. If it names someone else, you lost: walk away.

  Agents on one node share one graph, whose writes are serialised, so between
  them a claim is decided immediately. Across pods the verify step is what
  catches the race; `settle_ms` is how long it waits.

  ## Leases, not locks

  A claim carries `lease_until`. The holder renews it with `renew/3` (or any
  progress note) while it works; if it crashes, disconnects or stalls, the
  lease runs out and the task is open again for anyone. No failure detector,
  no cleanup job: the board heals by time alone.

  The guarantee is at-least-once, not exactly-once — a partition can let two
  agents work the same task until they see each other's claims. Tasks are
  written to be safe to redo, and duplicate results converge on one outcome.
  """

  alias JidoSwarm.Hive.Store

  @default_lease 300_000

  @type t :: %{
          task: String.t(),
          agent: String.t(),
          state: String.t(),
          lease_until: integer(),
          attempts: non_neg_integer(),
          summary: String.t(),
          at: integer()
        }

  @doc "Every claim on the board."
  @spec all() :: [t()]
  def all do
    Store.all("HiveClaim", ~w(task agent state lease_until attempts summary at))
    |> Enum.map(&Map.delete(&1, :key))
  end

  @doc "The claim on a task, or nil."
  @spec get(String.t()) :: t() | nil
  def get(task) do
    case Store.get(key(task)) do
      nil ->
        nil

      p ->
        %{
          task: p["task"],
          agent: p["agent"],
          state: p["state"],
          lease_until: p["lease_until"] || 0,
          attempts: p["attempts"] || 0,
          summary: p["summary"] || "",
          at: p["at"] || 0
        }
    end
  end

  @doc """
  The claim's effective state now: a `claimed` whose lease has run out reads as
  `expired`.
  """
  @spec state(t(), integer()) :: String.t()
  def state(%{state: "claimed", lease_until: until}, now) when is_integer(until) and until < now,
    do: "expired"

  def state(%{state: s}, _now), do: s

  @doc """
  Claims a task for `agent`, then verifies the claim held.

  Returns `{:ok, claim}` if `agent` holds the task afterwards, or
  `{:error, reason}` — `:not_open`, `{:held_by, other}` or `:lost_race`.
  """
  @spec claim(String.t(), String.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def claim(task, agent, opts \\ []) do
    lease = Keyword.get(opts, :lease_ms, @default_lease)
    settle = Keyword.get(opts, :settle_ms, settle_ms())
    now = Store.now()
    current = get(task)

    cond do
      current && state(current, now) == "claimed" && current.agent == agent ->
        renew(task, agent, lease)

      current && state(current, now) == "claimed" ->
        {:error, {:held_by, current.agent}}

      current && state(current, now) in ["done", "split"] ->
        {:error, :not_open}

      true ->
        attempts = (current && current.attempts) || 0
        :ok = write(task, agent, "claimed", now + lease, attempts, "")
        if settle > 0, do: Process.sleep(settle)
        Jido.Context.sync(Store.graph())

        case get(task) do
          %{agent: ^agent, state: "claimed"} = c -> {:ok, c}
          _ -> {:error, :lost_race}
        end
    end
  end

  @doc "Extends a lease the agent holds."
  @spec renew(String.t(), String.t(), non_neg_integer()) :: {:ok, t()} | {:error, term()}
  def renew(task, agent, lease \\ @default_lease) do
    case get(task) do
      %{agent: ^agent, state: "claimed"} = c ->
        :ok = write(task, agent, "claimed", Store.now() + lease, c.attempts, c.summary)
        {:ok, get(task)}

      %{agent: other} ->
        {:error, {:held_by, other}}

      nil ->
        {:error, :not_claimed}
    end
  end

  @doc "Hands a task back to the board unfinished. A note says where it got to."
  @spec release(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def release(task, agent, note \\ "") do
    with {:ok, c} <- holding(task, agent) do
      write(task, agent, "released", 0, c.attempts, note)
    end
  end

  @doc "Marks a task done by its holder, with a summary of the result."
  @spec complete(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def complete(task, agent, summary) do
    with {:ok, c} <- holding(task, agent) do
      write(task, agent, "done", 0, c.attempts, summary)
    end
  end

  @doc """
  Marks a failed attempt. The task reopens for another agent until it has
  failed `Board.max_attempts/0` times.
  """
  @spec fail(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def fail(task, agent, reason) do
    with {:ok, c} <- holding(task, agent),
         {:ok, _} <- JidoSwarm.Hive.Memory.note(agent, task, reason, "failure") do
      write(task, agent, "failed", 0, c.attempts + 1, reason)
    end
  end

  @doc false
  # Used by decomposition: marks a task as split into subtasks, whether or not
  # the splitter held it.
  def mark(task, agent, state, extra \\ %{}) do
    c = get(task)
    write(task, agent, state, 0, (c && c.attempts) || 0, Map.get(extra, :summary, ""))
  end

  @doc "Tasks an agent holds a live lease on."
  @spec held_by(String.t()) :: [t()]
  def held_by(agent) do
    now = Store.now()
    Enum.filter(all(), &(&1.agent == agent and state(&1, now) == "claimed"))
  end

  @doc "The graph key of a task's claim."
  @spec key(String.t()) :: String.t()
  def key(task), do: "claim:" <> task

  defp holding(task, agent) do
    case get(task) do
      %{agent: ^agent, state: "claimed"} = c -> {:ok, c}
      %{agent: other, state: "claimed"} -> {:error, {:held_by, other}}
      _ -> {:error, :not_claimed}
    end
  end

  defp write(task, agent, state, lease_until, attempts, summary) do
    Store.put(
      key(task),
      ["HiveClaim"],
      %{
        task: task,
        agent: agent,
        state: state,
        lease_until: lease_until,
        attempts: attempts,
        summary: summary,
        at: Store.now()
      },
      [{"CLAIMS", task, %{}}],
      :claims
    )
  end

  defp settle_ms, do: Application.get_env(:jido_swarm, :hive_settle_ms, 150)
end
