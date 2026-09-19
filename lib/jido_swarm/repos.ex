defmodule JidoSwarm.Repos do
  @moduledoc """
  The repositories the swarm works on, and the git operations it performs.

  ## The swarm never touches your working tree

  Every repository is cloned into a workspace directory the swarm owns, and all
  branching, editing and testing happens there. This is not politeness — agents
  acting on a checkout a person is also using is how you lose uncommitted work.
  The clone source is the local checkout when one is present (fast, offline),
  but `origin` is then repointed at the GitHub URL so pushes go where a PR can
  be opened from.

  ## Configuration

      config :jido_swarm, JidoSwarm.Repos,
        workspace: "/var/lib/jido_swarm/repos",
        repos: [
          %{
            name: "jido",
            url: "https://github.com/djcarpe/jido.git",
            source: "/home/dj/Work/jido",
            default_branch: "main",
            test_command: "mix test",
            description: "Autonomous agent framework for Elixir"
          }
        ]

  `:source` is optional — in the cluster there is no local checkout and the
  clone comes from `:url`.

  ## Credentials

  Pushing and opening pull requests need `GITHUB_TOKEN`. Without it the swarm
  still surveys, proposes, implements and runs tests; it stops at the push and
  records why. That is a deliberate degradation: a half-configured deployment
  should produce reviewable work, not errors.
  """

  require Logger

  @type repo :: %{
          name: String.t(),
          url: String.t(),
          source: String.t() | nil,
          default_branch: String.t(),
          test_command: String.t(),
          description: String.t()
        }

  @doc "Every configured repository."
  @spec all() :: [repo()]
  def all do
    config()
    |> Keyword.get(:repos, [])
    |> Enum.map(&normalize/1)
  end

  @doc "One repository by name."
  @spec fetch(String.t()) :: {:ok, repo()} | :error
  def fetch(name) do
    case Enum.find(all(), &(&1.name == name)) do
      nil -> :error
      repo -> {:ok, repo}
    end
  end

  defp normalize(repo) do
    %{
      name: repo.name,
      url: Map.get(repo, :url),
      source: Map.get(repo, :source),
      default_branch: Map.get(repo, :default_branch, "main"),
      test_command: Map.get(repo, :test_command, "mix test"),
      description: Map.get(repo, :description, "")
    }
  end

  @doc "The workspace root the swarm clones into."
  @spec workspace() :: String.t()
  def workspace do
    config() |> Keyword.get(:workspace, Path.join(System.tmp_dir!(), "jido_swarm_repos"))
  end

  @doc "Where a repository's clone lives."
  @spec path(repo() | String.t()) :: String.t()
  def path(%{name: name}), do: path(name)
  def path(name) when is_binary(name), do: Path.join(workspace(), name)

  # ===========================================================================
  # Clone
  # ===========================================================================

  @doc """
  Ensures the repository is cloned and on a clean default branch.

  Idempotent: an existing clone is fetched and reset rather than re-cloned.
  """
  @spec ensure_cloned(repo()) :: {:ok, String.t()} | {:error, term()}
  def ensure_cloned(repo) do
    dest = path(repo)

    if File.dir?(Path.join(dest, ".git")) do
      refresh(repo, dest)
    else
      clone(repo, dest)
    end
  end

  defp clone(repo, dest) do
    source = clone_source(repo)

    if is_nil(source) do
      {:error, {:no_clone_source, repo.name}}
    else
      File.mkdir_p!(Path.dirname(dest))

      with {:ok, _} <- git(["clone", "--no-hardlinks", source, dest], cd: Path.dirname(dest)),
           :ok <- point_origin_at_github(repo, dest) do
        Logger.info("swarm: cloned #{repo.name} from #{redact(source)}")
        {:ok, dest}
      end
    end
  end

  # A local checkout is the fastest source and works with no network, but its
  # `origin` would then be a filesystem path — useless for opening a PR. The URL
  # is restored immediately after cloning.
  defp point_origin_at_github(%{url: nil}, _dest), do: :ok

  defp point_origin_at_github(repo, dest) do
    case git(["remote", "set-url", "origin", push_url(repo)], cd: dest) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp refresh(repo, dest) do
    with {:ok, _} <- git(["fetch", "--prune", "origin"], cd: dest),
         {:ok, _} <- git(["checkout", repo.default_branch], cd: dest),
         {:ok, _} <- git(["reset", "--hard", "origin/" <> repo.default_branch], cd: dest) do
      {:ok, dest}
    else
      # A clone made from a local source may have no matching remote branch yet.
      # That is not fatal: the working copy is still usable for reading and for
      # branching from whatever it has.
      {:error, reason} ->
        Logger.debug("swarm: could not refresh #{repo.name}: #{inspect(reason)}")
        {:ok, dest}
    end
  end

  defp clone_source(repo) do
    cond do
      is_binary(repo.source) and File.dir?(Path.join(repo.source, ".git")) -> repo.source
      is_binary(repo.url) -> push_url(repo)
      true -> nil
    end
  end

  # ===========================================================================
  # Reading
  # ===========================================================================

  @doc """
  Lists tracked files, optionally filtered by a glob-ish substring.

  Uses `git ls-files` rather than walking the tree, so build artifacts and
  anything ignored never reach a prompt.
  """
  @spec list_files(repo(), String.t() | nil) :: {:ok, [String.t()]} | {:error, term()}
  def list_files(repo, filter \\ nil) do
    with {:ok, output} <- git(["ls-files"], cd: path(repo)) do
      files =
        output
        |> String.split("\n", trim: true)
        |> then(fn files ->
          if filter, do: Enum.filter(files, &String.contains?(&1, filter)), else: files
        end)

      {:ok, files}
    end
  end

  @doc """
  Reads a file from a repository.

  Refuses paths that escape the clone — a model-supplied path reaches this
  function, so containment is enforced rather than assumed.
  """
  @spec read_file(repo(), String.t(), pos_integer()) :: {:ok, String.t()} | {:error, term()}
  def read_file(repo, relative, max_bytes \\ 60_000) do
    with {:ok, absolute} <- safe_path(repo, relative) do
      case File.read(absolute) do
        {:ok, content} when byte_size(content) > max_bytes ->
          {:ok, binary_part(content, 0, max_bytes) <> "\n… (truncated)"}

        {:ok, content} ->
          {:ok, content}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc "Writes a file inside a repository, creating parent directories."
  @spec write_file(repo(), String.t(), String.t()) :: :ok | {:error, term()}
  def write_file(repo, relative, content) do
    with {:ok, absolute} <- safe_path(repo, relative) do
      File.mkdir_p!(Path.dirname(absolute))
      File.write(absolute, content)
    end
  end

  @doc """
  Resolves a repository-relative path, refusing anything outside the clone.
  """
  @spec safe_path(repo(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def safe_path(repo, relative) do
    root = repo |> path() |> Path.expand()
    candidate = root |> Path.join(relative) |> Path.expand()

    if candidate == root or String.starts_with?(candidate, root <> "/") do
      {:ok, candidate}
    else
      {:error, {:path_escapes_repo, relative}}
    end
  end

  @doc "A compact tree summary, for orienting a model without dumping the repo."
  @spec outline(repo(), pos_integer()) :: String.t()
  def outline(repo, limit \\ 200) do
    case list_files(repo) do
      {:ok, files} ->
        files
        |> Enum.reject(&String.starts_with?(&1, "."))
        |> Enum.take(limit)
        |> Enum.join("\n")

      {:error, _} ->
        ""
    end
  end

  # ===========================================================================
  # Branching, testing, pushing
  # ===========================================================================

  @doc "Creates and checks out a fresh branch from the default branch."
  @spec create_branch(repo(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def create_branch(repo, branch) do
    dest = path(repo)

    with {:ok, _} <- git(["checkout", repo.default_branch], cd: dest),
         {:ok, _} <- git(["checkout", "-B", branch], cd: dest) do
      {:ok, branch}
    end
  end

  @doc "Whether the working tree has changes."
  @spec dirty?(repo()) :: boolean()
  def dirty?(repo) do
    case git(["status", "--porcelain"], cd: path(repo)) do
      {:ok, ""} -> false
      {:ok, _} -> true
      _ -> false
    end
  end

  @doc "Stages everything and commits. Returns `:nothing_to_commit` when clean."
  @spec commit(repo(), String.t()) :: {:ok, String.t()} | :nothing_to_commit | {:error, term()}
  def commit(repo, message) do
    dest = path(repo)

    if dirty?(repo) do
      with {:ok, _} <- git(["add", "-A"], cd: dest),
           {:ok, _} <- git(["-c", "user.name=#{git_user()}", "-c", "user.email=#{git_email()}",
                            "commit", "-m", message], cd: dest),
           {:ok, sha} <- git(["rev-parse", "HEAD"], cd: dest) do
        {:ok, String.trim(sha)}
      end
    else
      :nothing_to_commit
    end
  end

  @doc """
  Runs the repository's test command.

  Returns `{:ok, output}` on a zero exit and `{:error, {exit_status, output}}`
  otherwise — a failing suite is a result the swarm records, not a crash.
  """
  @spec run_tests(repo(), keyword()) :: {:ok, String.t()} | {:error, {integer(), String.t()}}
  def run_tests(repo, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 600_000)
    command = Keyword.get(opts, :command, repo.test_command)

    task =
      Task.async(fn ->
        System.cmd("sh", ["-c", command],
          cd: path(repo),
          stderr_to_stdout: true,
          env: [{"MIX_ENV", "test"}]
        )
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, 0}} -> {:ok, tail(output)}
      {:ok, {output, status}} -> {:error, {status, tail(output)}}
      nil -> {:error, {:timeout, "test command exceeded #{timeout}ms"}}
    end
  end

  @doc "Pushes a branch to origin. Requires `GITHUB_TOKEN`."
  @spec push(repo(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def push(repo, branch) do
    if token() do
      case git(["push", "--set-upstream", push_url(repo), branch], cd: path(repo)) do
        {:ok, output} -> {:ok, tail(output)}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :no_github_token}
    end
  end

  @doc """
  Opens a pull request through the GitHub REST API.

  Uses the API rather than the `gh` CLI so the deployed container needs nothing
  but a token.
  """
  @spec open_pr(repo(), String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def open_pr(repo, branch, title, body) do
    with {:ok, slug} <- repo_slug(repo),
         true <- not is_nil(token()) || {:error, :no_github_token} do
      response =
        Req.post(
          url: "https://api.github.com/repos/#{slug}/pulls",
          headers: [
            {"authorization", "Bearer #{token()}"},
            {"accept", "application/vnd.github+json"},
            {"x-github-api-version", "2022-11-28"}
          ],
          json: %{
            "title" => title,
            "body" => body,
            "head" => branch,
            "base" => repo.default_branch
          },
          receive_timeout: 30_000
        )

      case response do
        {:ok, %{status: status, body: %{"html_url" => url}}} when status in 200..299 ->
          {:ok, url}

        {:ok, %{status: status, body: body}} ->
          {:error, {:github, status, body}}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, reason} -> {:error, reason}
      :error -> {:error, :unknown_repo_slug}
    end
  end

  @doc "`owner/name` parsed from the configured URL."
  @spec repo_slug(repo()) :: {:ok, String.t()} | :error
  def repo_slug(%{url: url}) when is_binary(url) do
    case Regex.run(~r{github\.com[:/]([^/]+/[^/.]+)}, url) do
      [_, slug] -> {:ok, slug}
      _ -> :error
    end
  end

  def repo_slug(_), do: :error

  @doc "Is the swarm able to push and open pull requests?"
  @spec can_publish?() :: boolean()
  def can_publish?, do: not is_nil(token())

  @doc "Why publishing is unavailable, for the UI."
  @spec publish_hint() :: String.t()
  def publish_hint do
    "Set GITHUB_TOKEN to let the swarm push branches and open pull requests. " <>
      "Without it, work stops after the tests run and the branch stays local."
  end

  # ===========================================================================
  # Helpers
  # ===========================================================================

  @doc false
  @spec git([String.t()], keyword()) :: {:ok, String.t()} | {:error, term()}
  def git(args, opts) do
    cd = Keyword.fetch!(opts, :cd)

    case System.cmd("git", args, cd: cd, stderr_to_stdout: true, env: git_env()) do
      {output, 0} -> {:ok, output}
      {output, status} -> {:error, {:git, status, String.trim(output)}}
    end
  rescue
    e -> {:error, {:git, Exception.message(e)}}
  end

  # Never prompt: a container has no terminal, and a hung credential prompt
  # would look like a wedged worker.
  defp git_env do
    [
      {"GIT_TERMINAL_PROMPT", "0"},
      {"GIT_ASKPASS", "true"},
      {"GIT_CONFIG_GLOBAL", "/dev/null"},
      {"GIT_CONFIG_SYSTEM", "/dev/null"}
    ]
  end

  defp push_url(%{url: url} = repo) do
    case {token(), repo_slug(repo)} do
      {token, {:ok, slug}} when is_binary(token) -> "https://x-access-token:#{token}@github.com/#{slug}.git"
      _ -> https_url(url)
    end
  end

  defp https_url("git@github.com:" <> rest), do: "https://github.com/" <> rest
  defp https_url(url), do: url

  defp redact(source) do
    String.replace(source, ~r{//[^@/]+@}, "//***@")
  end

  defp tail(output, lines \\ 60) do
    output
    |> String.split("\n")
    |> Enum.take(-lines)
    |> Enum.join("\n")
  end

  defp token, do: presence(System.get_env("GITHUB_TOKEN"))

  defp presence(nil), do: nil
  defp presence(""), do: nil
  defp presence(value), do: value

  defp git_user, do: Keyword.get(config(), :git_user, "jido-swarm")
  defp git_email, do: Keyword.get(config(), :git_email, "jido-swarm@localhost")

  defp config, do: Application.get_env(:jido_swarm, __MODULE__, [])
end
