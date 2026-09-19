defmodule JidoSwarm.Actions.Survey do
  @moduledoc """
  Reads a repository and records what it learned into the shared graph.

  The survey is the swarm's input stage: nothing gets proposed that is not
  grounded in a finding, and nothing becomes a finding without a worker having
  actually read the code. The prompt is fed the file list plus the contents of
  a handful of orienting files rather than the whole tree — a repository does
  not fit in a 4B model's useful attention span, and a truncated dump produces
  confident nonsense.
  """

  use Jido.Action,
    name: "swarm_survey",
    description: "Read a repository and record findings in the shared knowledge graph",
    schema: [
      repo: [type: :string, required: true, doc: "Repository name"],
      worker: [type: :string, default: "unknown"],
      count: [type: :integer, default: 3, doc: "How many findings to ask for"],
      job_id: [type: :string, default: "", doc: "Correlates the result with the dispatched job"]
    ]

  require Logger

  alias JidoSwarm.Knowledge
  alias JidoSwarm.Reasoning
  alias JidoSwarm.Repos

  # Files that tell a model what a project is, in the order they help most.
  @orienting_files ~w(README.md AGENTS.md usage-rules.md mix.exs Cargo.toml)

  @spec run(map(), map()) :: {:ok, map()}
  def run(params, _ctx) do
    JidoSwarm.Actions.outcome(params, fn -> do_run(params) end)
  end

  defp do_run(params) do
    with {:ok, repo} <- fetch_repo(params.repo),
         {:ok, _path} <- Repos.ensure_cloned(repo),
         {:ok, findings, usage} <- survey(repo, params.count) do
      graph = JidoSwarm.graph()

      recorded =
        Enum.map(findings, fn finding ->
          Knowledge.add_finding(graph, repo.name, Map.put(finding, :worker, params.worker))
          finding.summary
        end)

      {:ok, %{surveyed: repo.name, findings: recorded, usage: usage}}
    end
  end

  defp fetch_repo(name) do
    case Repos.fetch(name) do
      {:ok, repo} -> {:ok, repo}
      :error -> {:error, {:unknown_repo, name}}
    end
  end

  defp survey(repo, count) do
    context = build_context(repo)

    user = """
    Repository: #{repo.name}
    #{repo.description}

    Tracked files (truncated):
    #{context.outline}

    Key files:
    #{context.files}

    Identify #{count} specific, concrete observations about this codebase that would help
    decide what to build next. Prefer gaps, rough edges, and missing capabilities over praise.

    Respond with JSON only, in exactly this shape:
    {"findings": [{"summary": "one line", "detail": "2-4 sentences naming files or modules", "kind": "gap|pattern|risk"}]}
    """

    case Reasoning.ask_json(Reasoning.prompt(user), :object, max_tokens: 2000) do
      {:ok, value, result} ->
        case Reasoning.items(value, "findings") do
          [] -> {:error, {:no_findings_returned, value}}
          findings -> {:ok, Enum.map(findings, &normalize_finding/1), result.usage}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_finding(finding) when is_map(finding) do
    %{
      summary: Map.get(finding, "summary", "(no summary)"),
      detail: Map.get(finding, "detail", ""),
      kind: Map.get(finding, "kind", "observation")
    }
  end

  defp build_context(repo) do
    outline = repo |> Repos.outline(120) |> Reasoning.clamp(2_500)

    files =
      @orienting_files
      |> Enum.map(fn name ->
        case Repos.read_file(repo, name, 4_000) do
          {:ok, content} -> "--- #{name} ---\n" <> Reasoning.clamp(content, 4_000)
          {:error, _} -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n\n")
      |> Reasoning.clamp(12_000)

    %{outline: outline, files: files}
  end
end
