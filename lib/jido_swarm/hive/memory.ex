defmodule JidoSwarm.Hive.Memory do
  @moduledoc """
  What the swarm knows and says: the shared memory every agent reads before it
  works and writes into as it goes.

      (:HiveInsight)─[:ABOUT]→(task | goal | anything with a key)
      (:HiveInsight)─[:SUPPORTS | :CONTRADICTS]→(:HiveInsight)
      (:HiveEndorse)─[:ON]→(:HiveInsight)          one per agent, summed
      (:HiveQuestion)─[:ABOUT]→(task)   (:HiveAnswer)─[:ANSWERS]→(:HiveQuestion)
      (:HiveDecision)─[:ABOUT]→(task | goal)
      (:HiveNote)─[:ON]→(task)                     progress, handoff, blocker
      (:HiveArtifact)─[:PRODUCED_BY]→(task)
      (:HiveMessage)                               to one agent, or to a skill
      (:HiveTouch)─[:ON]→(task)                    interest, one per agent

  Everything here is append-only and written by its author alone, so it
  replicates without conflict. Two things are aggregates, and both are
  per-agent entities summed on read — a grow-only counter per agent, which is
  the one aggregate that converges under last-writer-wins:

  * **consensus** on an insight: the sum of endorsements (+1 / -1 per agent);
  * **heat** on a task: interest from agents who looked at it, decaying with
    time. The swarm's pheromone trail.
  """

  alias JidoSwarm.Hive.Agents
  alias JidoSwarm.Hive.Store

  @heat_half_life 600_000

  # ===========================================================================
  # Insights
  # ===========================================================================

  @kinds ~w(fact finding hypothesis risk idea summary)

  @doc """
  Shares an insight. `:about` is a list of keys it concerns; `:supports` and
  `:contradicts` link it to earlier insights; `:kind` is one of
  #{Enum.join(@kinds, ", ")}; `:confidence` is 0..1.
  """
  @spec share(String.t(), map()) :: {:ok, String.t()} | {:error, term()}
  def share(agent, attrs) do
    key = "insight:" <> Store.new_id("i")
    text = req!(attrs, :text)
    kind = get(attrs, :kind, "finding") |> to_string()
    kind = if kind in @kinds, do: kind, else: "finding"

    props = %{
      text: text,
      kind: kind,
      confidence: confidence(get(attrs, :confidence, 0.7)),
      tags: Agents.normalize_skills(get(attrs, :tags, [])),
      agent: agent,
      at: Store.now()
    }

    edges =
      Enum.map(List.wrap(get(attrs, :about, [])), &{"ABOUT", &1, %{}}) ++
        Enum.map(List.wrap(get(attrs, :supports, [])), &{"SUPPORTS", &1, %{}}) ++
        Enum.map(List.wrap(get(attrs, :contradicts, [])), &{"CONTRADICTS", &1, %{}})

    with :ok <- Store.put(key, ["HiveInsight"], props, edges, :memory), do: {:ok, key}
  end

  @doc "Endorses (+1) or disputes (-1) an insight. One vote per agent; the last one counts."
  @spec endorse(String.t(), String.t(), integer()) :: :ok | {:error, term()}
  def endorse(agent, insight, weight \\ 1) do
    w = if weight >= 0, do: 1, else: -1

    Store.put(
      "endorse:#{insight}:#{agent}",
      ["HiveEndorse"],
      %{insight: insight, agent: agent, weight: w, at: Store.now()},
      [{"ON", insight, %{}}],
      :signals
    )
  end

  @doc """
  Every insight with its consensus, the keys it is about, and what it supports
  or contradicts.
  """
  @spec insights() :: [map()]
  def insights do
    votes =
      Store.all("HiveEndorse", ~w(insight weight))
      |> Enum.group_by(& &1.insight, & &1.weight)
      |> Map.new(fn {k, ws} -> {k, Enum.sum(ws)} end)

    about = Store.edges("ABOUT") |> Enum.group_by(& &1.from, & &1.to)
    supports = Store.edges("SUPPORTS") |> Enum.group_by(& &1.from, & &1.to)
    contradicts = Store.edges("CONTRADICTS") |> Enum.group_by(& &1.from, & &1.to)
    contradicted_by = Store.edges("CONTRADICTS") |> Enum.group_by(& &1.to, & &1.from)

    Store.all("HiveInsight", ~w(text kind confidence tags agent at))
    |> Enum.map(fn i ->
      Map.merge(i, %{
        consensus: votes[i.key] || 0,
        about: about[i.key] || [],
        supports: supports[i.key] || [],
        contradicts: contradicts[i.key] || [],
        contradicted_by: contradicted_by[i.key] || []
      })
    end)
  end

  @doc """
  Insights relevant to some keys and text, best first: directly about one of
  `keys`, or sharing words with `text`, weighted by confidence, consensus and
  recency. The retrieval half of sharing context.
  """
  @spec relevant([String.t()], String.t(), pos_integer()) :: [map()]
  def relevant(keys, text, limit \\ 12) do
    want = MapSet.new(keys)
    words = words(text)
    now = Store.now()

    insights()
    |> Enum.map(fn i ->
      direct = Enum.any?(i.about, &MapSet.member?(want, &1))

      overlap =
        MapSet.size(MapSet.intersection(words, words(i.text <> " " <> Enum.join(i.tags, " "))))

      age_h = max(now - (i.at || now), 0) / 3_600_000

      score =
        if(direct, do: 3.0, else: 0.0) + min(overlap, 6) * 0.5 + (i.confidence || 0.5) +
          i.consensus * 0.5 - min(age_h / 24, 2) - length(i.contradicted_by) * 0.5

      {score, direct or overlap >= 2, i}
    end)
    |> Enum.filter(fn {_, keep, _} -> keep end)
    |> Enum.sort_by(fn {s, _, _} -> -s end)
    |> Enum.take(limit)
    |> Enum.map(fn {s, _, i} -> Map.put(i, :score, Float.round(s, 2)) end)
  end

  # ===========================================================================
  # Questions
  # ===========================================================================

  @doc """
  Asks the swarm. `:skills` routes it to agents who have them; `:about` ties it
  to a task so whoever works that task sees it.
  """
  @spec ask(String.t(), map()) :: {:ok, String.t()} | {:error, term()}
  def ask(agent, attrs) do
    key = "question:" <> Store.new_id("q")

    props = %{
      text: req!(attrs, :text),
      skills: Agents.normalize_skills(get(attrs, :skills, [])),
      agent: agent,
      at: Store.now()
    }

    edges = Enum.map(List.wrap(get(attrs, :about, [])), &{"ABOUT", &1, %{}})
    with :ok <- Store.put(key, ["HiveQuestion"], props, edges, :memory), do: {:ok, key}
  end

  @doc "Answers a question."
  @spec answer(String.t(), String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def answer(agent, question, text) do
    key = "answer:" <> Store.new_id("a")

    with :ok <-
           Store.put(
             key,
             ["HiveAnswer"],
             %{text: text, agent: agent, question: question, at: Store.now()},
             [{"ANSWERS", question, %{}}],
             :memory
           ),
         do: {:ok, key}
  end

  @doc "Every question with its answers and the keys it is about."
  @spec questions() :: [map()]
  def questions do
    answers = Store.all("HiveAnswer", ~w(text agent question at)) |> Enum.group_by(& &1.question)
    about = Store.edges("ABOUT") |> Enum.group_by(& &1.from, & &1.to)

    Store.all("HiveQuestion", ~w(text skills agent at))
    |> Enum.map(fn q ->
      as = Enum.sort_by(answers[q.key] || [], & &1.at)
      Map.merge(q, %{answers: as, answered: as != [], about: about[q.key] || []})
    end)
    |> Enum.sort_by(& &1.at, :desc)
  end

  # ===========================================================================
  # Decisions, notes, artifacts
  # ===========================================================================

  @doc "Records a decision, and why, about some keys."
  @spec decide(String.t(), map()) :: {:ok, String.t()} | {:error, term()}
  def decide(agent, attrs) do
    key = "decision:" <> Store.new_id("d")

    props = %{
      text: req!(attrs, :text),
      rationale: get(attrs, :rationale, ""),
      agent: agent,
      at: Store.now()
    }

    edges = Enum.map(List.wrap(get(attrs, :about, [])), &{"ABOUT", &1, %{}})
    with :ok <- Store.put(key, ["HiveDecision"], props, edges, :memory), do: {:ok, key}
  end

  @doc "Every decision with the keys it is about."
  @spec decisions() :: [map()]
  def decisions do
    about = Store.edges("ABOUT") |> Enum.group_by(& &1.from, & &1.to)

    Store.all("HiveDecision", ~w(text rationale agent at))
    |> Enum.map(&Map.put(&1, :about, about[&1.key] || []))
    |> Enum.sort_by(& &1.at, :desc)
  end

  @doc """
  Leaves a note on a task. `kind` is `"progress"`, `"handoff"` (for whoever
  picks it up next), `"blocker"`, or `"failure"` (written by `Claims.fail/3`,
  so an agent's failures survive the next agent's claim).
  """
  @spec note(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def note(agent, task, text, kind \\ "progress") do
    key = "note:" <> Store.new_id("n")
    kind = if kind in ~w(progress handoff blocker failure), do: kind, else: "progress"

    with :ok <-
           Store.put(
             key,
             ["HiveNote"],
             %{text: text, kind: kind, agent: agent, task: task, at: Store.now()},
             [{"ON", task, %{}}],
             :memory
           ),
         do: {:ok, key}
  end

  @doc "Failure notes, as `%{task => count}` for one agent."
  @spec failures_of(String.t()) :: %{String.t() => non_neg_integer()}
  def failures_of(agent) do
    Store.all("HiveNote", ~w(kind agent task))
    |> Enum.filter(&(&1.kind == "failure" and &1.agent == agent))
    |> Enum.frequencies_by(& &1.task)
  end

  @doc "Notes on the given tasks, newest first."
  @spec notes([String.t()]) :: [map()]
  def notes(tasks) do
    want = MapSet.new(tasks)

    Store.all("HiveNote", ~w(text kind agent task at))
    |> Enum.filter(&MapSet.member?(want, &1.task))
    |> Enum.sort_by(& &1.at, :desc)
  end

  @doc "Records something a task produced: a file, a PR, a document, a URL."
  @spec artifact(String.t(), String.t(), map()) :: {:ok, String.t()} | {:error, term()}
  def artifact(agent, task, attrs) do
    key = "artifact:" <> Store.new_id("r")

    props = %{
      uri: req!(attrs, :uri),
      kind: get(attrs, :kind, "file"),
      summary: get(attrs, :summary, ""),
      agent: agent,
      task: task,
      at: Store.now()
    }

    with :ok <- Store.put(key, ["HiveArtifact"], props, [{"PRODUCED_BY", task, %{}}], :memory),
         do: {:ok, key}
  end

  @doc "Artifacts produced by the given tasks."
  @spec artifacts([String.t()]) :: [map()]
  def artifacts(tasks) do
    want = MapSet.new(tasks)

    Store.all("HiveArtifact", ~w(uri kind summary agent task at))
    |> Enum.filter(&MapSet.member?(want, &1.task))
  end

  # ===========================================================================
  # Messages
  # ===========================================================================

  @doc """
  Sends a message to one agent (`to: "agent_…"`), to every agent with a skill
  (`to: "skill:rust"`), or to everyone (`to: "*"`).
  """
  @spec message(String.t(), String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def message(from, to, text) do
    key = "message:" <> Store.new_id("m")

    with :ok <-
           Store.put(
             key,
             ["HiveMessage"],
             %{from: from, to: to, text: text, at: Store.now()},
             :memory
           ),
         do: {:ok, key}
  end

  @doc "Messages addressed to an agent, directly, by one of its skills, or to all."
  @spec messages_for(String.t(), [String.t()], integer()) :: [map()]
  def messages_for(agent, skills, since \\ 0) do
    targets = MapSet.new([agent, "*" | Enum.map(skills, &("skill:" <> &1))])

    Store.all("HiveMessage", ~w(from to text at))
    |> Enum.filter(
      &(MapSet.member?(targets, &1.to) and (&1.at || 0) > since and &1.from != agent)
    )
    |> Enum.sort_by(& &1.at, :desc)
  end

  # ===========================================================================
  # Heat
  # ===========================================================================

  @doc """
  Records that an agent looked at a task. Interest decays with a ten-minute
  half-life; the scheduler uses it to spread agents out rather than herding
  them onto the same few tasks.
  """
  @spec touch(String.t(), String.t()) :: :ok | {:error, term()}
  def touch(agent, task) do
    key = "touch:#{task}:#{agent}"
    prev = Store.get(key)
    n = ((prev && prev["n"]) || 0) + 1

    Store.put(
      key,
      ["HiveTouch"],
      %{task: task, agent: agent, n: n, at: Store.now()},
      [{"ON", task, %{}}],
      :signals
    )
  end

  @doc "Heat per task: decayed interest summed over agents."
  @spec heat() :: %{String.t() => float()}
  def heat do
    now = Store.now()

    Store.all("HiveTouch", ~w(task agent n at))
    |> Enum.reduce(%{}, fn t, acc ->
      decay = :math.pow(0.5, max(now - (t.at || now), 0) / @heat_half_life)
      Map.update(acc, t.task, decay, &(&1 + decay))
    end)
  end

  # ===========================================================================
  # Helpers
  # ===========================================================================

  @stop ~w(the a an and or of to in on for with is are be this that it as at by from into not no)

  @doc false
  def words(text) do
    text
    |> to_string()
    |> String.downcase()
    |> String.split(~r/[^a-z0-9_]+/u, trim: true)
    |> Enum.reject(&(String.length(&1) < 3 or &1 in @stop))
    |> MapSet.new()
  end

  defp confidence(c) when is_number(c), do: c |> max(0.0) |> min(1.0) |> Kernel.*(1.0)

  defp confidence(c) when is_binary(c),
    do:
      c
      |> Float.parse()
      |> then(fn
        {f, _} -> confidence(f)
        _ -> 0.7
      end)

  defp confidence(_), do: 0.7

  defp get(attrs, k, default), do: Map.get(attrs, k) || Map.get(attrs, to_string(k)) || default

  defp req!(attrs, k) do
    case get(attrs, k, nil) do
      v when is_binary(v) and v != "" -> v
      _ -> raise ArgumentError, "#{k} is required"
    end
  end
end
