defmodule JidoSwarm.Actions.Chat do
  @moduledoc """
  Answers the operator, grounded in the shared knowledge graph.

  The model is given what the swarm actually knows — findings, proposals,
  attempts — rather than being asked to recall anything. This is the read side
  of the graph paying for itself: the answer cites work that really happened,
  and the operator can go look at it.

  Unlike the other actions this one returns prose, and the answer is both sent
  to the waiting LiveView and written into the graph on `context.chat`, so a
  second browser sees the same conversation.
  """

  use Jido.Action,
    name: "swarm_chat",
    description: "Answer an operator question using the shared knowledge graph",
    schema: [
      prompt: [type: :string, required: true],
      worker: [type: :string, default: "unknown"],
      job_id: [type: :string, default: "", doc: "Correlates the result with the dispatched job"]
    ]

  alias JidoSwarm.Knowledge
  alias JidoSwarm.LLM
  alias JidoSwarm.Reasoning

  @spec run(map(), map()) :: {:ok, map()}
  def run(params, _ctx) do
    JidoSwarm.Actions.outcome(params, fn -> do_run(params) end)
  end

  defp do_run(params) do
    graph = JidoSwarm.graph()

    messages = [
      %{role: :system, content: system_prompt()},
      %{role: :user, content: user_prompt(graph, params.prompt)}
    ]

    case LLM.chat(messages, max_tokens: 2_000) do
      {:ok, result} ->
        answer = String.trim(result.text)

        Knowledge.add_chat_turn(graph, %{
          role: :assistant,
          body: answer,
          worker: params.worker
        })

        {:ok, %{answer: answer, usage: result.usage, model: result.model}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The shared system prompt tells workers to answer in JSON; a chat reply is
  # the one place that is wrong, so this one stands alone.
  defp system_prompt do
    """
    You are the voice of a swarm of Elixir agents working on jido (an agent framework),
    glider (an embedded property-graph database in Rust), and glider_ex (its Elixir NIF bindings).

    You are answering the operator who runs the swarm. Be direct and concrete. Ground every
    claim in the swarm's recorded knowledge, which is given to you below. If the swarm has not
    learned something yet, say so plainly and suggest what to run — a survey of a repo, or a
    proposal — rather than speculating.

    Answer in prose. Keep it short unless asked for detail.
    """
  end

  defp user_prompt(graph, question) do
    summary = Knowledge.summary(graph)

    findings =
      graph
      |> Knowledge.findings()
      |> Enum.take(15)
      |> Enum.map_join("\n", fn f -> "- [#{f.kind}] #{f.summary}" end)
      |> presence("(none recorded yet)")

    proposals =
      graph
      |> Knowledge.proposals()
      |> Enum.take(15)
      |> Enum.map_join("\n", fn p -> "- [#{p.status}] #{p.repo}: #{p.title}" end)
      |> presence("(none yet)")

    attempts =
      graph
      |> Knowledge.attempts()
      |> Enum.take(10)
      |> Enum.map_join("\n", fn a ->
        "- [#{a.status}] #{a.repo} #{a.branch} #{a.pr_url}"
      end)
      |> presence("(none yet)")

    history =
      graph
      |> Knowledge.chat_turns(10)
      |> Enum.map_join("\n", fn t -> "#{t.role}: #{Reasoning.clamp(t.body, 500)}" end)
      |> presence("(start of conversation)")

    """
    What the swarm knows right now:
    #{summary.repos} repositories, #{summary.findings} findings, #{summary.proposals} proposals, #{summary.attempts} attempts.

    Findings:
    #{findings}

    Proposals:
    #{proposals}

    Implementation attempts:
    #{attempts}

    Recent conversation:
    #{history}

    The operator asks:
    #{question}
    """
  end

  defp presence("", fallback), do: fallback
  defp presence(value, _fallback), do: value
end
