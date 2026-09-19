defmodule JidoSwarm.Actions.Propose do
  @moduledoc """
  Turns findings about a repository into one concrete feature proposal.

  Proposals are linked back to the findings that motivated them, so the graph
  answers "why is this worth building" without anyone having to remember. A
  worker that has no findings to work from asks for a survey instead of
  inventing a rationale.
  """

  use Jido.Action,
    name: "swarm_propose",
    description: "Turn findings into a feature proposal in the shared knowledge graph",
    schema: [
      repo: [type: :string, required: true],
      worker: [type: :string, default: "unknown"],
      job_id: [type: :string, default: "", doc: "Correlates the result with the dispatched job"]
    ]

  alias JidoSwarm.Knowledge
  alias JidoSwarm.Reasoning
  alias JidoSwarm.Repos

  @spec run(map(), map()) :: {:ok, map()}
  def run(params, _ctx) do
    JidoSwarm.Actions.outcome(params, fn -> do_run(params) end)
  end

  defp do_run(params) do
    graph = JidoSwarm.graph()

    with {:ok, repo} <- fetch_repo(params.repo),
         findings when findings != [] <- Knowledge.findings(graph, repo.name),
         {:ok, proposal} <- propose(repo, findings) do
      {:ok, key} =
        Knowledge.add_proposal(
          graph,
          repo.name,
          proposal
          |> Map.put(:worker, params.worker)
          |> Map.put(:supported_by, Enum.map(Enum.take(findings, 5), & &1.key))
        )

      {:ok, %{proposed: key, title: proposal.title, repo: repo.name}}
    else
      [] -> {:error, {:no_findings, params.repo}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_repo(name) do
    case Repos.fetch(name) do
      {:ok, repo} -> {:ok, repo}
      :error -> {:error, {:unknown_repo, name}}
    end
  end

  defp propose(repo, findings) do
    existing =
      JidoSwarm.graph()
      |> Knowledge.proposals()
      |> Enum.filter(&(&1.repo == repo.name))
      |> Enum.map_join("\n", &"- #{&1.title}")

    findings_text =
      findings
      |> Enum.take(10)
      |> Enum.map_join("\n", fn f -> "- [#{f.kind}] #{f.summary}" end)

    user = """
    Repository: #{repo.name}
    #{repo.description}

    What the swarm has learned about it:
    #{findings_text}

    Features already proposed (do not repeat these):
    #{if existing == "", do: "(none yet)", else: existing}

    Propose ONE new feature worth building. It must be small enough to implement in a single
    reviewable pull request, and must follow from the findings above.

    Respond with JSON only, in exactly this shape:
    {"title": "short imperative title",
     "rationale": "why this is worth doing, referencing the findings",
     "sketch": "how to implement it: which files to add or change, and what goes in them"}
    """

    case Reasoning.ask_json(Reasoning.prompt(user), :object, max_tokens: 2000) do
      {:ok, %{"title" => title} = proposal, _result} when is_binary(title) and title != "" ->
        {:ok,
         %{
           title: title,
           rationale: Map.get(proposal, "rationale", ""),
           sketch: Map.get(proposal, "sketch", "")
         }}

      {:ok, other, _result} ->
        {:error, {:unexpected_shape, other}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
