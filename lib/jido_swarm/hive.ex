defmodule JidoSwarm.Hive do
  @moduledoc """
  A self-organising swarm over the shared knowledge graph.

  The rest of `JidoSwarm` is a central queue feeding a pool of workers. The
  Hive is the other way to run a swarm: there is no dispatcher. Goals, tasks,
  claims, knowledge and conversation all live in the replicated
  `Jido.Context` graph (Glider underneath), and every agent — a Jido worker
  here, a worker on another pod, a Claude Code session over MCP — reads the
  same board and decides for itself what to do next.

  ## How a swarm organises itself here

  * **A shared board (blackboard).** Goals break into tasks; tasks break into
    subtasks and depend on each other (`JidoSwarm.Hive.Board`). Anyone can add
    work, and whoever takes a task too big for one agent splits it.
  * **Self-selection (stigmergy).** Each agent ranks open tasks by the same
    visible rule — priority, skill fit, its own track record, neglect, and how
    many others are already looking — and claims the best one it can win
    (`JidoSwarm.Hive.Scheduler`). Interest decays like a pheromone, spreading
    agents out instead of herding them.
  * **Leases, not locks.** A claim holds for a lease that the holder renews as
    it works (`JidoSwarm.Hive.Claims`). A crashed or disconnected agent simply
    stops renewing and its work returns to the board.
  * **Context packs.** Before working, an agent reads one task's pack: the
    goal, the parent chain, handoff notes, inputs, decisions, the most
    relevant insights, open questions, and who is doing what nearby
    (`JidoSwarm.Hive.ContextPack`). A newcomer starts where the swarm is.
  * **Attributed, weighted knowledge.** Insights carry a kind, a confidence
    and a consensus score from endorsements; contradictions are links, shown
    rather than overwritten (`JidoSwarm.Hive.Memory`).
  * **Questions, decisions, handoffs, messages.** Agents ask by skill, answer
    each other, record decisions with rationale, leave handoff notes when they
    let go of a task, and message one agent, a skill, or everyone.

  Everything replicates by topic (`hive.**`) over the mesh, converging by
  last-writer-wins per entity; `JidoSwarm.Hive.Store` explains how the schema
  is shaped so concurrent agents never overwrite each other.

  ## The work loop

      {:ok, me} = Hive.join(name: "planner", skills: ["elixir", "design"])
      {:ok, work} = Hive.next_task(me.id)          # ranks, claims, returns the pack
      # ... do the work, sharing as you go:
      Hive.share(me.id, %{text: "…", about: [work.task.key], confidence: 0.8})
      Hive.progress(me.id, work.task.key, "halfway: parser done")   # renews the lease
      Hive.finish(me.id, work.task.key, "Implemented X; see artifact", insights: [...])

  The same loop is exposed to external agents as MCP tools by
  `JidoSwarm.MCP`.
  """

  alias JidoSwarm.Hive.Agents
  alias JidoSwarm.Hive.Board
  alias JidoSwarm.Hive.Claims
  alias JidoSwarm.Hive.ContextPack
  alias JidoSwarm.Hive.Memory
  alias JidoSwarm.Hive.Scheduler
  alias JidoSwarm.Hive.Store

  # Membership
  defdelegate join(opts), to: Agents
  defdelegate heartbeat(id, status \\ nil), to: Agents
  defdelegate leave(id), to: Agents
  defdelegate agents(), to: Agents, as: :active

  # Board
  defdelegate add_goal(attrs), to: Board
  defdelegate add_task(attrs), to: Board
  defdelegate decompose(task, subtasks, agent), to: Board
  defdelegate depend(task, on), to: Board
  defdelegate goals(), to: Board
  defdelegate tasks(), to: Board
  defdelegate task(key), to: Board

  # Claims
  defdelegate claim(task, agent, opts \\ []), to: Claims
  defdelegate renew(task, agent, lease \\ 300_000), to: Claims
  defdelegate release(task, agent, note \\ ""), to: Claims

  # Memory
  defdelegate share(agent, attrs), to: Memory
  defdelegate endorse(agent, insight, weight \\ 1), to: Memory
  defdelegate ask(agent, attrs), to: Memory
  defdelegate answer(agent, question, text), to: Memory
  defdelegate decide(agent, attrs), to: Memory
  defdelegate artifact(agent, task, attrs), to: Memory
  defdelegate message(from, to, text), to: Memory
  defdelegate insights(), to: Memory
  defdelegate questions(), to: Memory

  # Scheduling and context
  defdelegate ranked(agent, opts \\ []), to: Scheduler
  defdelegate context(task, opts \\ []), to: ContextPack, as: :build

  @doc """
  Picks, claims and briefs: the best open task for this agent, claimed, with
  its context pack. `:none` when there is nothing this agent should do.
  """
  @spec next_task(String.t(), keyword()) :: {:ok, %{task: map(), context: String.t()}} | :none
  def next_task(agent, opts \\ []) do
    Agents.heartbeat(agent, "working")

    case Scheduler.next(agent, opts) do
      {:ok, task} ->
        {:ok, pack} = ContextPack.build(task.key, Keyword.put(opts, :agent, agent))
        {:ok, %{task: task, context: pack.markdown}}

      :none ->
        Agents.heartbeat(agent, "idle")
        :none
    end
  end

  @doc """
  Reports progress on a held task: leaves a note and renews the lease, so an
  agent that keeps talking keeps its work.
  """
  @spec progress(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def progress(agent, task, text) do
    with {:ok, _} <- Claims.renew(task, agent),
         {:ok, _} <- Memory.note(agent, task, text, "progress") do
      Agents.heartbeat(agent, "working")
    end
  end

  @doc """
  Finishes a held task. Options record what came out of it in the same step:
  `:insights` (maps for `share/2`, auto-linked to the task), `:artifacts`
  (maps with `:uri`), `:decisions`.
  """
  @spec finish(String.t(), String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def finish(agent, task, summary, opts \\ []) do
    with :ok <- record_outputs(agent, task, opts),
         :ok <- Claims.complete(task, agent, summary) do
      Agents.heartbeat(agent, "idle")
    end
  end

  @doc "Gives up on a held task, recording why; it reopens for others."
  @spec fail(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def fail(agent, task, reason), do: Claims.fail(task, agent, reason)

  @doc "Lets go of a held task with a handoff note for whoever takes it next."
  @spec handoff(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def handoff(agent, task, note) do
    with {:ok, _} <- Memory.note(agent, task, note, "handoff") do
      Claims.release(task, agent, note)
    end
  end

  @doc """
  Everything addressed to an agent: messages, open questions matching its
  skills, and leases it holds that are close to running out.
  """
  @spec inbox(String.t(), integer()) :: map()
  def inbox(agent_id, since \\ 0) do
    agent = Agents.get(agent_id)
    skills = (agent && agent.skills) || []
    now = Store.now()

    %{
      messages: Memory.messages_for(agent_id, skills, since),
      questions:
        Enum.filter(Memory.questions(), fn q ->
          not q.answered and q.agent != agent_id and
            (q.skills == [] or Enum.any?(q.skills, &(&1 in skills)))
        end),
      expiring:
        Claims.held_by(agent_id)
        |> Enum.filter(&(&1.lease_until - now < 60_000))
        |> Enum.map(&Map.take(&1, [:task, :lease_until]))
    }
  end

  @doc """
  The board at a glance, for an agent deciding what to do or a human watching:
  goals and progress, work in flight, the best open tasks, open questions, and
  who is here.
  """
  @spec digest(keyword()) :: map()
  def digest(opts \\ []) do
    tasks = Board.tasks()
    by = Enum.group_by(tasks, & &1.status)
    limit = Keyword.get(opts, :limit, 10)

    %{
      goals: Enum.map(Board.goals(), &Map.take(&1, [:key, :title, :priority, :tasks, :done])),
      counts: Map.new(by, fn {s, ts} -> {s, length(ts)} end),
      in_flight:
        Enum.map(
          by["claimed"] || [],
          &%{
            key: &1.key,
            title: &1.title,
            agent: &1.claim.agent,
            lease_until: &1.claim.lease_until
          }
        ),
      open:
        (by["open"] || [])
        |> Enum.sort_by(&{-(&1.priority || 0), &1.created_at})
        |> Enum.take(limit)
        |> Enum.map(&Map.take(&1, [:key, :title, :priority, :skills])),
      blocked: Enum.map(by["blocked"] || [], &Map.take(&1, [:key, :title, :depends_on])),
      open_questions:
        Memory.questions()
        |> Enum.reject(& &1.answered)
        |> Enum.take(limit)
        |> Enum.map(&Map.take(&1, [:key, :text, :skills, :agent])),
      recent_insights:
        Memory.insights()
        |> Enum.sort_by(& &1.at, :desc)
        |> Enum.take(limit)
        |> Enum.map(&Map.take(&1, [:key, :text, :kind, :confidence, :consensus, :agent])),
      agents: Enum.map(Agents.active(), &Map.take(&1, [:id, :name, :kind, :skills, :status]))
    }
  end

  @doc """
  Finds tasks, goals, insights, questions and decisions whose text shares words
  with `text`, best match first.
  """
  @spec search(String.t(), pos_integer()) :: [map()]
  def search(text, limit \\ 20) do
    want = Memory.words(text)

    candidates =
      Enum.map(
        Board.tasks(),
        &%{key: &1.key, kind: "task", text: &1.title <> " " <> &1.detail, status: &1.status}
      ) ++
        Enum.map(
          Board.goals(),
          &%{key: &1.key, kind: "goal", text: &1.title <> " " <> &1.description}
        ) ++
        Enum.map(
          Memory.insights(),
          &%{key: &1.key, kind: "insight", text: &1.text, consensus: &1.consensus}
        ) ++
        Enum.map(
          Memory.questions(),
          &%{key: &1.key, kind: "question", text: &1.text, answered: &1.answered}
        ) ++
        Enum.map(Memory.decisions(), &%{key: &1.key, kind: "decision", text: &1.text})

    candidates
    |> Enum.map(&{MapSet.size(MapSet.intersection(want, Memory.words(&1.text))), &1})
    |> Enum.filter(fn {n, _} -> n > 0 end)
    |> Enum.sort_by(fn {n, _} -> -n end)
    |> Enum.take(limit)
    |> Enum.map(fn {n, c} -> Map.put(c, :matches, n) end)
  end

  @write_words ~w(CREATE SET DELETE DETACH REMOVE MERGE DROP INDEX CLEAR COMPACT BEGIN COMMIT ROLLBACK)

  @doc """
  Runs a read-only Cypher query against the shared graph. Writes are refused:
  the graph converges only if every change goes through a delta, so a raw
  `CREATE` here would exist on one replica and nowhere else.
  """
  @spec read_query(String.t()) :: {:ok, map()} | {:error, String.t()}
  def read_query(cypher) do
    upper = String.upcase(cypher)

    cond do
      Enum.any?(@write_words, &Regex.match?(~r/\b#{&1}\b/, upper)) ->
        {:error, "read-only: use the Hive tools to change the board, so the change replicates"}

      Regex.match?(~r/CALL\s+\w+\s*\([^)]*write\s*:/i, cypher) ->
        {:error, "read-only: algorithm write-back is not allowed here"}

      true ->
        case Jido.Context.query(Store.graph(), cypher) do
          {:ok, result} -> {:ok, Map.take(Map.new(result), [:columns, :rows, :message])}
          {:error, reason} -> {:error, to_string(inspect(reason))}
        end
    end
  end

  defp record_outputs(agent, task, opts) do
    results =
      Enum.map(Keyword.get(opts, :insights, []), fn i ->
        about = Enum.uniq([task | List.wrap(Map.get(i, :about) || Map.get(i, "about") || [])])

        Memory.share(
          agent,
          i |> Map.new(fn {k, v} -> {to_string(k), v} end) |> Map.put("about", about)
        )
      end) ++
        Enum.map(Keyword.get(opts, :artifacts, []), &Memory.artifact(agent, task, &1)) ++
        Enum.map(Keyword.get(opts, :decisions, []), fn d ->
          Memory.decide(
            agent,
            d |> Map.new(fn {k, v} -> {to_string(k), v} end) |> Map.put("about", [task])
          )
        end)

    case Enum.find(results, &match?({:error, _}, &1)) do
      nil -> :ok
      err -> err
    end
  end
end
