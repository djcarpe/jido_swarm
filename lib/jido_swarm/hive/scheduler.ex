defmodule JidoSwarm.Hive.Scheduler do
  @moduledoc """
  How agents pick work without anyone assigning it.

  Every agent scores the open tasks with the same visible rule and tries to
  claim the best one; if it loses the claim it tries the next. There is no
  dispatcher to scale or to fail, and an agent that joins mid-flight is
  productive on its first call.

  ## The score

      priority × 10                       what the swarm said matters
    + skill fit × 6                       tasks tagged with skills this agent has
    + track record × 2                    skills this agent has finished tasks in
    + neglect (up to 5)                   open tasks get more attractive with age
    − heat × 3                            others are already looking: spread out
    − 15 per earlier failure by this agent
    + jitter (0..1)                       so identical agents do not collide

  A task that needs skills the agent lacks entirely is skipped unless it has
  sat open for `orphan_after` (default ten minutes) — better a generalist try
  it than nobody.
  """

  alias JidoSwarm.Hive.Agents
  alias JidoSwarm.Hive.Board
  alias JidoSwarm.Hive.Claims
  alias JidoSwarm.Hive.Memory
  alias JidoSwarm.Hive.Store

  @orphan_after 600_000

  @doc """
  Open tasks ranked for an agent, best first, each with its score and why.
  """
  @spec ranked(String.t(), keyword()) :: [map()]
  def ranked(agent_id, opts \\ []) do
    agent = Agents.get(agent_id)
    skills = MapSet.new(Keyword.get(opts, :skills) || (agent && agent.skills) || [])
    tasks = Board.tasks()
    heat = Memory.heat()
    record = track_record(agent_id, tasks)
    failures = failures(agent_id)
    now = Store.now()

    tasks
    |> Enum.filter(&(&1.status == "open"))
    |> Enum.map(&score(&1, skills, record, failures, heat, now, :rand.uniform()))
    |> Enum.filter(& &1.eligible)
    |> Enum.sort_by(&(-&1.score))
  end

  @doc """
  One task through every active agent's eyes: the score each would give it
  and the parts that make it up, best first. Without the jitter, so the
  numbers are the rule and nothing else; a real pick adds up to one point of
  noise on top.
  """
  @spec explain(String.t()) :: {:ok, [map()]} | {:error, :no_such_task}
  def explain(task_key) do
    tasks = Board.tasks()

    case Enum.find(tasks, &(&1.key == task_key)) do
      nil ->
        {:error, :no_such_task}

      task ->
        heat = Memory.heat()
        now = Store.now()

        rows =
          Agents.active()
          |> Enum.map(fn agent ->
            scored =
              score(
                task,
                MapSet.new(agent.skills || []),
                track_record(agent.id, tasks),
                failures(agent.id),
                heat,
                now,
                0.0
              )

            %{
              agent: agent.id,
              name: agent.name,
              kind: agent.kind,
              skills: agent.skills || [],
              score: scored.score,
              eligible: scored.eligible,
              why: scored.why
            }
          end)
          |> Enum.sort_by(&(-&1.score))

        {:ok, rows}
    end
  end

  # The rule, once, for one task and one agent's skills, record and failures.
  defp score(t, skills, record, failures, heat, now, jitter) do
    need = MapSet.new(t.skills || [])

    fit =
      if MapSet.size(need) == 0,
        do: 0.5,
        else: MapSet.size(MapSet.intersection(need, skills)) / MapSet.size(need)

    rec = need |> Enum.map(&Map.get(record, &1, 0)) |> Enum.sum() |> min(5) |> Kernel./(5)
    age = max(now - (t.created_at || now), 0)
    neglect = min(age / 120_000, 5.0)
    h = Map.get(heat, t.key, 0.0)
    failed = Map.get(failures, t.key, 0)

    score = (t.priority || 3) * 10 + fit * 6 + rec * 2 + neglect - h * 3 - failed * 15 + jitter
    eligible = fit > 0 or MapSet.size(need) == 0 or age >= @orphan_after

    Map.merge(t, %{
      score: Float.round(score * 1.0, 2),
      eligible: eligible,
      why: %{
        priority: t.priority,
        skill_fit: Float.round(fit * 1.0, 2),
        record: Float.round(rec * 1.0, 2),
        neglect: Float.round(neglect * 1.0, 2),
        heat: Float.round(h * 1.0, 2),
        my_failures: failed
      }
    })
  end

  @doc """
  Picks and claims the best task for an agent. Tries the top few in order, so
  losing a race costs one retry, not a round trip to the caller.

  Returns `{:ok, task}` (claimed) or `:none`.
  """
  @spec next(String.t(), keyword()) :: {:ok, map()} | :none
  def next(agent_id, opts \\ []) do
    agent_id
    |> ranked(opts)
    |> Enum.take(Keyword.get(opts, :tries, 5))
    |> Enum.find_value(:none, fn t ->
      case Claims.claim(t.key, agent_id, opts) do
        {:ok, claim} ->
          Memory.touch(agent_id, t.key)
          {:ok, Map.merge(t, %{status: "claimed", claim: claim})}

        {:error, _} ->
          nil
      end
    end)
  end

  # Tasks finished, per skill, by this agent.
  defp track_record(agent_id, tasks) do
    tasks
    |> Enum.filter(&((&1.status == "done" and &1.claim) && &1.claim.agent == agent_id))
    |> Enum.flat_map(&(&1.skills || []))
    |> Enum.frequencies()
  end

  defp failures(agent_id), do: Memory.failures_of(agent_id)
end
