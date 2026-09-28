defmodule JidoSwarm.Hive.ContextPack do
  @moduledoc """
  Everything an agent needs to work one task, read out of the shared graph and
  cut to a budget.

  This is the answer to "how does a new agent pick up where the swarm is?"
  without replaying a transcript or trusting a model's memory: the pack is
  assembled from facts other agents wrote, each attributed, so the agent knows
  who said what and how sure they were.

  ## Sections, in the order they survive a tight budget

  1. **Task** — what to do, the acceptance criteria, attempts so far
  2. **Why** — the goal and the chain of parent tasks
  3. **Handoffs** — notes from agents who worked this before, newest first
  4. **Inputs** — dependencies, their result summaries and artifacts
  5. **Decisions** — what was already settled about this task or its parents
  6. **Knowledge** — the most relevant insights, with consensus, and any
     contradictions flagged rather than hidden
  7. **Open questions** — asked about this task, answered or not
  8. **Around you** — sibling tasks and who holds them, so agents coordinate
     instead of colliding

  Rendered as Markdown for a model's prompt; `build/2` also returns the
  structured sections for tools that want data, and `sources` — the keys of
  the entities each section was assembled from, so a console can point at
  the exact nodes in the shared graph an agent was handed.
  """

  alias JidoSwarm.Hive.Agents
  alias JidoSwarm.Hive.Board
  alias JidoSwarm.Hive.Memory

  @default_budget 12_000

  @doc """
  Builds the pack for a task. `:budget` is in characters (about four per
  token); `:agent` records the read as interest in the task.
  """
  @spec build(String.t(), keyword()) :: {:ok, map()} | {:error, :no_such_task}
  def build(task_key, opts \\ []) do
    tasks = Board.tasks()
    by_key = Map.new(tasks, &{&1.key, &1})

    case by_key[task_key] do
      nil ->
        {:error, :no_such_task}

      task ->
        if agent = opts[:agent], do: Memory.touch(agent, task_key)
        budget = Keyword.get(opts, :budget, @default_budget)
        chain = ancestors(task, by_key)
        goal = Enum.find(Board.goals(), &(&1.key == task.goal))
        deps = Enum.map(task.depends_on, &by_key[&1]) |> Enum.reject(&is_nil/1)

        siblings =
          Enum.filter(
            tasks,
            &(&1.parent == task.parent and &1.key != task.key and task.parent != "")
          )

        lineage =
          [task.key | Enum.map(chain, & &1.key)] ++ Enum.reject([task.goal], &(&1 in [nil, ""]))

        notes = Memory.notes([task.key])
        artifacts = Memory.artifacts(Enum.map(deps, & &1.key))

        decisions =
          Enum.filter(Memory.decisions(), &Enum.any?(&1.about, fn k -> k in lineage end))

        insights = Memory.relevant(lineage ++ task.depends_on, task.title <> " " <> task.detail)

        questions =
          Enum.filter(Memory.questions(), &Enum.any?(&1.about, fn k -> k in lineage end))

        active = Agents.active()

        sections = [
          {:task, render_task(task)},
          {:why, render_why(goal, chain)},
          {:handoffs, render_notes(notes)},
          {:inputs, render_inputs(deps, artifacts)},
          {:decisions, render_decisions(decisions)},
          {:knowledge, render_insights(insights)},
          {:questions, render_questions(questions)},
          {:around, render_around(siblings, active)}
        ]

        # The same lists the sections were rendered from, cut where the
        # renderers cut, as keys: what the agent was actually shown.
        sources = %{
          task: [task.key],
          why: keys([goal | chain]),
          handoffs: keys(Enum.take(notes, 8)),
          inputs: keys(deps) ++ keys(artifacts),
          decisions: keys(Enum.take(decisions, 8)),
          knowledge: keys(insights),
          questions:
            keys(Enum.take(questions, 6)) ++
              keys(Enum.flat_map(Enum.take(questions, 6), & &1.answers)),
          around:
            keys(Enum.take(siblings, 10)) ++ Enum.map(Enum.take(active, 12), &Agents.key(&1.id))
        }

        {:ok,
         %{
           task: task,
           sections: Map.new(sections),
           sources: sources,
           markdown: fit(sections, budget)
         }}
    end
  end

  # Keep whole sections in priority order while they fit; truncate the first
  # one that does not, and drop the rest.
  defp fit(sections, budget) do
    {parts, _} =
      Enum.reduce(sections, {[], budget}, fn {_, text}, {acc, left} ->
        cond do
          text == "" -> {acc, left}
          left <= 0 -> {acc, left}
          byte_size(text) <= left -> {[text | acc], left - byte_size(text) - 2}
          left > 200 -> {[String.slice(text, 0, left - 20) <> "\n…(truncated)" | acc], 0}
          true -> {acc, 0}
        end
      end)

    parts |> Enum.reverse() |> Enum.join("\n\n")
  end

  defp render_task(t) do
    """
    # Task: #{t.title}
    key: `#{t.key}` · status: #{t.status} · priority: #{t.priority}/5 · attempts: #{t.attempts}#{skills(t.skills)}

    #{blank(t.detail, "(no detail given)")}
    #{if t.acceptance not in [nil, ""], do: "\n**Done when:** " <> t.acceptance, else: ""}
    """
    |> String.trim()
  end

  defp render_why(nil, []), do: ""

  defp render_why(goal, chain) do
    g =
      if goal,
        do:
          "**Goal:** #{goal.title}#{if goal.description != "", do: " — " <> goal.description, else: ""}\n",
        else: ""

    c = Enum.map_join(Enum.reverse(chain), "\n", &"- part of `#{&1.key}`: #{&1.title}")
    ("## Why\n" <> g <> c) |> String.trim()
  end

  defp render_notes([]), do: ""

  defp render_notes(notes) do
    "## Notes from earlier work\n" <>
      Enum.map_join(Enum.take(notes, 8), "\n", &"- [#{&1.kind}] #{&1.agent}: #{&1.text}")
  end

  defp render_inputs([], _), do: ""

  defp render_inputs(deps, artifacts) do
    arts = Enum.group_by(artifacts, & &1.task)

    "## Inputs (dependencies)\n" <>
      Enum.map_join(deps, "\n", fn d ->
        summary =
          if d.claim && d.claim.summary not in [nil, ""], do: " — " <> d.claim.summary, else: ""

        a = Enum.map_join(arts[d.key] || [], "", &"\n  - artifact: #{&1.uri} #{&1.summary}")
        "- `#{d.key}` #{d.title} [#{d.status}]#{summary}#{a}"
      end)
  end

  defp render_decisions([]), do: ""

  defp render_decisions(ds) do
    "## Decisions already made\n" <>
      Enum.map_join(Enum.take(ds, 8), "\n", fn d ->
        "- #{d.text}#{if d.rationale != "", do: " (because: #{d.rationale})", else: ""} — #{d.agent}"
      end)
  end

  defp render_insights([]), do: ""

  defp render_insights(is) do
    "## What the swarm knows\n" <>
      Enum.map_join(is, "\n", fn i ->
        flag =
          if i.contradicted_by != [],
            do: " ⚠ disputed by #{Enum.join(i.contradicted_by, ", ")}",
            else: ""

        "- [#{i.kind}, conf #{i.confidence}, +#{i.consensus}] #{i.text} — #{i.agent} (`#{i.key}`)#{flag}"
      end)
  end

  defp render_questions([]), do: ""

  defp render_questions(qs) do
    "## Questions\n" <>
      Enum.map_join(Enum.take(qs, 6), "\n", fn q ->
        a = Enum.map_join(q.answers, "", &"\n  - answer (#{&1.agent}): #{&1.text}")
        "- #{if q.answered, do: "answered", else: "OPEN"} `#{q.key}`: #{q.text}#{a}"
      end)
  end

  defp render_around(siblings, active) do
    s =
      Enum.map_join(Enum.take(siblings, 10), "\n", fn t ->
        who = if t.claim && t.status == "claimed", do: " (held by #{t.claim.agent})", else: ""
        "- `#{t.key}` #{t.title} [#{t.status}]#{who}"
      end)

    a = Enum.map_join(Enum.take(active, 12), ", ", &"#{&1.name}#{skills(&1.skills)}")

    body =
      [if(s != "", do: "Sibling tasks:\n" <> s), if(a != "", do: "Active agents: " <> a)]
      |> Enum.reject(&is_nil/1)

    if body == [], do: "", else: "## Around you\n" <> Enum.join(body, "\n")
  end

  defp ancestors(task, by_key, acc \\ []) do
    case by_key[task.parent] do
      nil -> Enum.reverse(acc)
      p -> if p in acc, do: Enum.reverse(acc), else: ancestors(p, by_key, [p | acc])
    end
  end

  defp keys(items), do: items |> Enum.map(&(&1 && Map.get(&1, :key))) |> Enum.reject(&is_nil/1)

  defp skills([]), do: ""
  defp skills(s), do: " · skills: " <> Enum.join(s, ", ")

  defp blank(v, default) when v in [nil, ""], do: default
  defp blank(v, _), do: v
end
