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
  """

  use Jido.Action,
    name: "swarm_hive_work",
    description: "Work one task from the self-organising Hive board",
    schema: [
      task: [type: :string, required: true],
      context: [type: :string, default: ""],
      worker: [type: :string, default: "unknown"],
      job_id: [type: :string, default: ""]
    ]

  alias JidoSwarm.Hive
  alias JidoSwarm.Reasoning

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

    case Reasoning.ask_json(Reasoning.prompt(prompt(context)), :object, max_tokens: 4_000) do
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
  defp with_text(answer, key) do
    case Map.get(answer, key) do
      list when is_list(list) ->
        Enum.filter(list, &(is_map(&1) and is_binary(&1["text"]) and &1["text"] != ""))

      _ ->
        []
    end
  end

  defp prompt(context) do
    """
    You have claimed the task below from the swarm's shared board. Everything the
    swarm knows that bears on it is included: read it before you decide.

    #{Reasoning.clamp(context, 14_000)}

    Do the task as far as you can with what you know, then answer with ONE JSON object:

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
