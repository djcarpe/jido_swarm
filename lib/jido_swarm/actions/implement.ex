defmodule JidoSwarm.Actions.Implement do
  @moduledoc """
  Implements a proposal on a branch, runs the test suite, and opens a pull
  request.

  The stages are recorded into the graph as they happen — `started`,
  `edited`, `tests_passed` / `tests_failed`, `pushed`, `pr_opened` — so an
  attempt that stops halfway is legible afterwards rather than simply absent.

  ## What it will not do

  * **It never touches your checkout.** All work happens in the swarm's own
    clone (`JidoSwarm.Repos`).
  * **It does not open a pull request over failing tests.** A red suite ends the
    attempt with the output recorded. Opening PRs regardless would turn the
    swarm into a machine for generating review burden.
  * **It does not write outside the repository.** Model-supplied paths go
    through `JidoSwarm.Repos.safe_path/2`.
  * **It does not push without `GITHUB_TOKEN`.** The branch and its commit stay
    in the workspace, and the attempt says so.
  """

  use Jido.Action,
    name: "swarm_implement",
    description: "Implement a proposal on a branch, run tests, and open a pull request",
    schema: [
      proposal_key: [type: :string, required: true],
      worker: [type: :string, default: "unknown"],
      require_green_tests: [type: :boolean, default: true],
      job_id: [type: :string, default: "", doc: "Correlates the result with the dispatched job"]
    ]

  require Logger

  alias JidoSwarm.Knowledge
  alias JidoSwarm.Reasoning
  alias JidoSwarm.Repos

  @max_files 6

  # Below this, a file is small enough that a large proportional change is
  # ordinary rather than suspicious.
  @small_file_lines 40

  # A rewrite retaining less of the original than this is treated as truncation.
  @min_retained_ratio 0.5

  @spec run(map(), map()) :: {:ok, map()}
  def run(params, _ctx) do
    JidoSwarm.Actions.outcome(params, fn -> do_run(params) end)
  end

  defp do_run(params) do
    graph = JidoSwarm.graph()

    with {:ok, proposal} <- fetch_proposal(graph, params.proposal_key),
         {:ok, repo} <- fetch_repo(proposal.repo),
         {:ok, _} <- Repos.ensure_cloned(repo) do
      branch = branch_name(proposal)

      {:ok, attempt} =
        Knowledge.add_attempt(graph, params.proposal_key, %{
          status: "started",
          branch: branch,
          repo: repo.name,
          worker: params.worker
        })

      execute(graph, attempt, repo, proposal, branch, params)
    end
  end

  defp execute(graph, attempt, repo, proposal, branch, params) do
    with {:ok, _} <- Repos.create_branch(repo, branch),
         {:ok, edits} <- draft_edits(repo, proposal),
         :ok <- apply_edits(repo, edits),
         :ok <- note(graph, attempt, "edited", repo, branch, "#{length(edits)} file(s) changed"),
         {:ok, test_output} <- verify(graph, attempt, repo, branch, params) do
      Knowledge.set_proposal_status(graph, proposal.key, "implemented")
      publish(graph, attempt, repo, proposal, branch, test_output, params)
    else
      {:error, reason} = error ->
        Knowledge.update_attempt(graph, attempt, %{
          status: "failed",
          branch: branch,
          repo: repo.name,
          note: inspect(reason),
          worker: params.worker
        })

        error
    end
  end

  # ===========================================================================
  # Drafting
  # ===========================================================================

  defp draft_edits(repo, proposal) do
    context = relevant_files(repo, proposal)

    user = """
    Repository: #{repo.name}
    #{repo.description}

    Implement this proposal:

    Title: #{proposal.title}
    Rationale: #{proposal.rationale}
    Sketch: #{Map.get(proposal, :sketch, "")}

    Tracked files (truncated):
    #{context.outline}

    Contents of the most relevant existing files:
    #{context.files}

    Write the complete new contents of every file you need to add or change. Keep the change
    small and reviewable — at most #{@max_files} files. Match the surrounding style. If the
    project has tests, include one.

    Strongly prefer adding NEW files over rewriting existing ones. When you must change an
    existing file you have to reproduce it in full, and omitting any part of it deletes that
    part. If a file is long, find a way to make the change by adding a new module instead.

    Respond with JSON only, in exactly this shape:
    {"files": [{"path": "lib/foo/bar.ex", "contents": "<the entire file>"}],
     "summary": "one paragraph describing the change"}
    """

    # Drafting whole files is the longest generation the swarm does. 16k output
    # tokens is minutes of wall clock on a 4B local model — past the provider's
    # default timeout — and a small model asked for that much mostly repeats
    # itself. A tighter budget with a longer deadline finishes more often.
    case Reasoning.ask_json(Reasoning.prompt(user), :object,
           max_tokens: 6_000,
           timeout: 600_000
         ) do
      {:ok, value, _result} ->
        edits =
          value
          |> Reasoning.items("files")
          |> Enum.take(@max_files)
          |> Enum.map(&normalize_edit/1)
          |> Enum.reject(&is_nil/1)

        if edits == [], do: {:error, {:no_usable_edits, value}}, else: {:ok, edits}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_edit(%{"path" => path, "contents" => contents})
       when is_binary(path) and is_binary(contents) and path != "" do
    %{path: path, contents: contents}
  end

  defp normalize_edit(_), do: nil

  defp apply_edits(_repo, []), do: {:error, :no_usable_edits}

  defp apply_edits(repo, edits) do
    with {:ok, safe} <- reject_truncations(repo, edits) do
      Enum.reduce_while(safe, :ok, fn edit, :ok ->
        case Repos.write_file(repo, edit.path, edit.contents) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, {:write_failed, edit.path, reason}}}
        end
      end)
    end
  end

  # Guards against the characteristic failure of asking a small model to
  # "write the complete new contents" of a large file: it writes the part it
  # was thinking about and silently drops the rest. Observed in practice — a
  # 1555-line module came back as 35 lines, deleting 1889 lines across the
  # change. The tests caught it, but a plausible-looking truncation that still
  # compiled would not have been caught, and the model had no idea it had done
  # anything wrong.
  #
  # A rewrite that keeps less than @min_retained_ratio of the original is
  # treated as truncation, not as an intentional deletion. Genuinely deleting
  # most of a file is rare, and asking for it again is cheap; shipping a
  # silently gutted module is not.
  defp reject_truncations(repo, edits) do
    {safe, truncated} = Enum.split_with(edits, &acceptable_size?(repo, &1))

    cond do
      truncated != [] ->
        paths = Enum.map_join(truncated, ", ", & &1.path)
        {:error, {:truncated_rewrite, paths}}

      safe == [] ->
        {:error, :no_usable_edits}

      true ->
        {:ok, safe}
    end
  end

  defp acceptable_size?(repo, edit) do
    case Repos.read_file(repo, edit.path, 2_000_000) do
      # A new file has nothing to shrink from.
      {:error, _} ->
        true

      {:ok, existing} ->
        existing_lines = count_lines(existing)

        existing_lines <= @small_file_lines or
          count_lines(edit.contents) / existing_lines >= @min_retained_ratio
    end
  end

  defp count_lines(text), do: text |> String.split("\n") |> length()

  # The model is shown files whose names overlap the proposal's own words. Crude,
  # but it beats both a random sample and the whole tree, and it costs nothing.
  defp relevant_files(repo, proposal) do
    terms =
      "#{proposal.title} #{Map.get(proposal, :sketch, "")}"
      |> String.downcase()
      |> String.split(~r/[^a-z0-9_]+/, trim: true)
      |> Enum.filter(&(String.length(&1) > 3))
      |> Enum.uniq()

    {:ok, all_files} = Repos.list_files(repo)

    scored =
      all_files
      |> Enum.filter(&source_file?/1)
      |> Enum.map(fn file ->
        name = String.downcase(file)
        {file, Enum.count(terms, &String.contains?(name, &1))}
      end)
      |> Enum.filter(fn {_file, score} -> score > 0 end)
      |> Enum.sort_by(fn {_file, score} -> -score end)
      |> Enum.take(4)
      |> Enum.map(&elem(&1, 0))

    files =
      scored
      |> Enum.map(fn file ->
        case Repos.read_file(repo, file, 8_000) do
          {:ok, content} -> "--- #{file} ---\n#{content}"
          {:error, _} -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n\n")
      |> Reasoning.clamp(18_000)

    %{outline: repo |> Repos.outline(120) |> Reasoning.clamp(2_500), files: files}
  end

  defp source_file?(path) do
    String.ends_with?(path, [".ex", ".exs", ".rs", ".md"]) and
      not String.starts_with?(path, "_build/")
  end

  # ===========================================================================
  # Verifying and publishing
  # ===========================================================================

  defp verify(graph, attempt, repo, branch, params) do
    case Repos.run_tests(repo) do
      {:ok, output} ->
        note(graph, attempt, "tests_passed", repo, branch, tail(output))
        {:ok, output}

      {:error, {status, output}} ->
        note(
          graph,
          attempt,
          "tests_failed",
          repo,
          branch,
          "exit #{inspect(status)}\n#{tail(output)}"
        )

        if params.require_green_tests do
          {:error, {:tests_failed, status}}
        else
          {:ok, output}
        end
    end
  end

  defp publish(graph, attempt, repo, proposal, branch, test_output, params) do
    message = commit_message(proposal)

    case Repos.commit(repo, message) do
      :nothing_to_commit ->
        note(graph, attempt, "no_changes", repo, branch, "the edits left the tree unchanged")
        {:ok, %{attempt: attempt, status: "no_changes", branch: branch}}

      {:error, reason} ->
        {:error, {:commit_failed, reason}}

      {:ok, sha} ->
        note(graph, attempt, "committed", repo, branch, sha)
        maybe_open_pr(graph, attempt, repo, proposal, branch, test_output, params)
    end
  end

  defp maybe_open_pr(graph, attempt, repo, proposal, branch, test_output, params) do
    if Repos.can_publish?() do
      with {:ok, _} <- Repos.push(repo, branch),
           :ok <- note(graph, attempt, "pushed", repo, branch, ""),
           {:ok, url} <-
             Repos.open_pr(repo, branch, proposal.title, pr_body(proposal, test_output)) do
        Knowledge.update_attempt(graph, attempt, %{
          status: "pr_opened",
          branch: branch,
          repo: repo.name,
          pr_url: url,
          worker: params.worker
        })

        Knowledge.set_proposal_status(graph, proposal.key, "pr_opened")
        {:ok, %{attempt: attempt, status: "pr_opened", pr_url: url, branch: branch}}
      else
        {:error, reason} ->
          note(graph, attempt, "publish_failed", repo, branch, inspect(reason))

          {:ok,
           %{attempt: attempt, status: "publish_failed", branch: branch, error: inspect(reason)}}
      end
    else
      note(graph, attempt, "committed_not_pushed", repo, branch, Repos.publish_hint())
      {:ok, %{attempt: attempt, status: "committed_not_pushed", branch: branch}}
    end
  end

  # ===========================================================================
  # Helpers
  # ===========================================================================

  defp note(graph, attempt, status, repo, branch, note) do
    Knowledge.update_attempt(graph, attempt, %{
      status: status,
      branch: branch,
      repo: repo.name,
      note: Reasoning.clamp(note, 4_000)
    })

    :ok
  end

  defp fetch_proposal(graph, key) do
    case Knowledge.proposal(graph, key) do
      nil -> {:error, {:unknown_proposal, key}}
      proposal -> {:ok, proposal}
    end
  end

  defp fetch_repo(name) do
    case Repos.fetch(name) do
      {:ok, repo} -> {:ok, repo}
      :error -> {:error, {:unknown_repo, name}}
    end
  end

  defp branch_name(proposal) do
    slug =
      proposal.title
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")
      |> String.slice(0, 40)

    "swarm/" <> slug <> "-" <> (:crypto.strong_rand_bytes(3) |> Base.encode16(case: :lower))
  end

  defp commit_message(proposal) do
    """
    feat: #{proposal.title}

    #{Reasoning.clamp(proposal.rationale, 1_000)}

    Proposed and implemented by the Jido swarm.
    """
  end

  defp pr_body(proposal, test_output) do
    """
    ## What

    #{proposal.title}

    ## Why

    #{proposal.rationale}

    ## How

    #{Map.get(proposal, :sketch, "")}

    ## Tests

    ```
    #{tail(test_output)}
    ```

    ---

    Opened by the Jido swarm. The proposal and the findings behind it are in the
    shared knowledge graph under `#{proposal.key}`.
    """
  end

  defp tail(output, lines \\ 30) do
    output
    |> to_string()
    |> String.split("\n")
    |> Enum.take(-lines)
    |> Enum.join("\n")
  end
end
