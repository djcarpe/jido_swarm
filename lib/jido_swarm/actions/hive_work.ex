defmodule JidoSwarm.Actions.HiveWork do
  @moduledoc """
  Works one Hive task the worker claimed for itself.

  The model gets the task's context pack — goal, parents, handoff notes,
  inputs, decisions, relevant knowledge, who is nearby — and answers with one
  JSON document saying what happened:

  | outcome | the swarm sees |
  |---|---|
  | `done` | the task completes with a summary; insights and decisions are recorded against it |
  | `decompose` | the task splits into subtasks others can pick up in parallel |
  | `handoff` | the task returns to the board with a note for the next agent |
  | `fail` | the attempt is recorded; the task reopens until it has failed three times |

  Questions in the answer go to the Hive routed by skill, so a worker that is
  stuck on something outside its skills asks rather than guesses.

  ## Repositories

  A task that names a repository — in its title, its detail, or its key —
  gets that repository in hand: the clone is made or refreshed, an outline
  and its README go into the prompt, and the model may `list_files`,
  `read_file` and `grep` it (`JidoSwarm.Repos.Tools`) as many times as it
  needs before answering. The first round of standing surveys ran without
  this and every agent said so, in questions and in failure notes; a survey
  that cannot read the code is a survey of the task's own wording.
  """

  use Jido.Action,
    name: "swarm_hive_work",
    description: "Work one task from the self-organising Hive board",
    schema: [
      task: [type: :string, required: true],
      context: [type: :string, default: ""],
      worker: [type: :string, default: "unknown"],
      job_id: [type: :string, default: ""],
      model: [
        type: :string,
        default: "",
        doc:
          "The model for this task (PROVIDER/MODEL on ragentic); the provider's default when empty"
      ]
    ]

  alias JidoSwarm.Hive
  alias JidoSwarm.Reasoning
  alias JidoSwarm.Repos

  @tool_rounds 16
  # A survey that read forty files has a lot to say; the cap is generous and
  # an answer that still overruns is asked for again, shorter.
  @max_tokens 16_000

  @spec run(map(), map()) :: {:ok, map()}
  def run(params, _ctx) do
    JidoSwarm.Actions.outcome(params, fn -> do_run(params) end)
  end

  defp do_run(params) do
    %{task: task, worker: me} = params

    context =
      case params.context do
        "" -> with({:ok, p} <- Hive.context(task, agent: me), do: p.markdown, else: (_ -> ""))
        c -> c
      end

    repos = repos_for(task, context) |> Enum.filter(&cloned?/1)
    messages = Reasoning.prompt(prompt(context, repos))

    model = JidoSwarm.Actions.model_opt(params)

    ask =
      if repos == [] do
        Reasoning.ask_json(messages, :object, [max_tokens: @max_tokens] ++ model)
      else
        Reasoning.ask_json_with_tools(
          messages,
          :object,
          Repos.Tools.definitions(),
          &Repos.Tools.call(&1, &2, repos),
          [max_tokens: @max_tokens, max_rounds: @tool_rounds] ++ model
        )
      end

    case ask do
      {:ok, answer, _result} ->
        apply_answer(me, task, answer)

      {:error, reason} ->
        Hive.fail(me, task, ("model error: " <> inspect(reason)) |> String.slice(0, 500))
        {:error, reason}
    end
  end

  @doc false
  # Applies a model answer to the board. Public for tests.
  def apply_answer(me, task, answer) when is_map(answer) do
    insights = with_text(answer, "insights")
    decisions = with_text(answer, "decisions")

    for q <- with_text(answer, "questions") do
      Hive.ask(me, %{"text" => q["text"], "skills" => q["skills"] || [], "about" => [task]})
    end

    summary = to_string(answer["summary"] || "")

    result =
      case answer["outcome"] do
        "decompose" ->
          subtasks =
            case answer["subtasks"] do
              l when is_list(l) -> Enum.filter(l, &(is_map(&1) and is_binary(&1["title"])))
              _ -> []
            end

          Enum.each(insights, &Hive.share(me, Map.put(&1, "about", [task])))

          if subtasks == [],
            do:
              Hive.handoff(me, task, "wanted to split this but proposed no subtasks: " <> summary),
            else: with({:ok, _} <- Hive.decompose(task, subtasks, me), do: :ok)

        "handoff" ->
          Enum.each(insights, &Hive.share(me, Map.put(&1, "about", [task])))
          Hive.handoff(me, task, answer["note"] || summary)

        "fail" ->
          Enum.each(insights, &Hive.share(me, Map.put(&1, "about", [task])))
          Hive.fail(me, task, summary)

        _done ->
          Hive.finish(me, task, if(summary == "", do: "done", else: summary),
            insights: insights,
            decisions: decisions
          )
      end

    case result do
      :ok -> {:ok, %{task: task, outcome: answer["outcome"] || "done", summary: summary}}
      {:error, reason} -> {:error, reason}
    end
  end

  def apply_answer(me, task, _other) do
    Hive.handoff(me, task, "the model's answer was not a JSON object")
    {:error, :bad_answer}
  end

  # Only items that actually say something: `Reasoning.items/2` is lenient
  # about shape, and a model may omit a list or fill it with fragments.
  defp repo_brief([]), do: ""

  defp repo_brief(repos) do
    briefs =
      Enum.map_join(repos, "\n\n", fn repo ->
        readme =
          case Repos.read_file(repo, "README.md", 3_000) do
            {:ok, text} -> "README.md:\n" <> Reasoning.clamp(text, 3_000)
            _ -> "(no README.md)"
          end

        """
        ### #{repo.name} — checked out at #{Repos.path(repo)}
        #{Reasoning.clamp(Repos.outline(repo, 80), 2_000)}

        #{readme}
        """
      end)

    """

    ## Repositories in hand

    You have these repositories on disk and three tools to read them: list_files,
    read_file and grep, each taking the repository name. Use them — read the code
    before you write an insight about it, and cite paths in what you record. Do
    not ask how to reach the repository; you have it.

    #{briefs}
    """
  end

  defp with_text(answer, key) do
    case Map.get(answer, key) do
      list when is_list(list) ->
        Enum.filter(list, &(is_map(&1) and is_binary(&1["text"]) and &1["text"] != ""))

      _ ->
        []
    end
  end

  @doc false
  # The repositories a task is about: named in its key (the steward's
  # `task:standing:<repo>:<n>`), its title or its detail, or as `repo:<name>`
  # anywhere in the context pack. Public for tests.
  @spec repos_for(String.t(), String.t()) :: [Repos.repo()]
  def repos_for(task_key, context) do
    haystack = String.downcase(task_key <> "\n" <> context)

    Repos.all()
    |> Enum.filter(fn repo ->
      name = String.downcase(repo.name)

      String.starts_with?(task_key, "task:standing:#{repo.name}:") or
        String.contains?(haystack, "repo:#{name}") or
        Regex.match?(~r/(^|[^a-z0-9_])#{Regex.escape(name)}([^a-z0-9_]|$)/, haystack)
    end)
  end

  defp cloned?(repo) do
    case Repos.ensure_cloned(repo) do
      {:ok, _} ->
        true

      {:error, reason} ->
        require Logger
        Logger.warning("hive work: could not clone #{repo.name}: #{inspect(reason)}")
        false
    end
  end

  defp prompt(context, repos) do
    """
    You have claimed the task below from the swarm's shared board. Everything the
    swarm knows that bears on it is included: read it before you decide.

    #{Reasoning.clamp(context, 14_000)}
    #{repo_brief(repos)}

    Do the task as far as you can with what you know, then answer with ONE JSON object.
    Keep it compact: cite paths, but keep the summary under 800 characters and each
    insight under 500; prefer more insights over longer ones.

    {
      "outcome": "done" | "decompose" | "handoff" | "fail",
      "summary": "what you did or concluded, specific enough for the next agent",
      "insights": [{"text": "...", "kind": "fact|finding|hypothesis|risk|idea|summary", "confidence": 0.0-1.0}],
      "decisions": [{"text": "...", "rationale": "..."}],
      "subtasks": [{"title": "...", "detail": "...", "acceptance": "...", "skills": ["..."], "priority": 1-5, "depends_on": [index]}],
      "questions": [{"text": "...", "skills": ["..."]}],
      "note": "for handoff: what is done, what is left, what to watch out for"
    }

    - "done" only if the acceptance criteria are met by what you produced.
    - "decompose" if the task is too big for one step: give 2-6 subtasks that can run in parallel where possible.
    - "handoff" if you made progress but cannot finish; "fail" if the task itself is wrong or impossible (say why).
    - Share insights other agents would want even if you finish. Ask questions instead of guessing.
    """
  end
end
