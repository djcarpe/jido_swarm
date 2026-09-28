defmodule JidoSwarm.Repos.Tools do
  @moduledoc """
  What a model may do to a repository while it thinks: list, read, search.

  Read-only by construction. An agent working a Hive task gets these three
  tools and nothing else, so the worst a confused model can do is read the
  wrong file. Every path goes through `JidoSwarm.Repos.safe_path/2`, which
  refuses anything outside the clone, and every result is cut to a size a
  context window can afford.

  The tool definitions are in `JidoSwarm.LLM`'s shape; `call/3` executes
  one, returning the text the model gets back.
  """

  alias JidoSwarm.Repos

  @max_files 300
  @max_matches 120
  @max_read_bytes 40_000
  @default_window 200

  @doc "The tool definitions, for `JidoSwarm.LLM.chat/2`'s `:tools`."
  @spec definitions() :: [JidoSwarm.LLM.tool()]
  def definitions do
    [
      %{
        name: "list_files",
        description:
          "List files in a repository, optionally matching a glob such as lib/**/*.ex or " <>
            "src/*.rs. Paths are relative to the repository root. Up to #{@max_files} files.",
        schema: %{
          "type" => "object",
          "properties" => %{
            "repo" => %{"type" => "string", "description" => "repository name"},
            "glob" => %{"type" => "string", "description" => "optional glob, default everything"}
          },
          "required" => ["repo"]
        }
      },
      %{
        name: "read_file",
        description:
          "Read a file from a repository, optionally a window of lines. Returns numbered " <>
            "lines. Large files are cut; ask for a window to read further.",
        schema: %{
          "type" => "object",
          "properties" => %{
            "repo" => %{"type" => "string"},
            "path" => %{
              "type" => "string",
              "description" => "path relative to the repository root"
            },
            "start_line" => %{
              "type" => "integer",
              "description" => "first line, 1-based; default 1"
            },
            "lines" => %{
              "type" => "integer",
              "description" => "how many lines; default #{@default_window}"
            }
          },
          "required" => ["repo", "path"]
        }
      },
      %{
        name: "grep",
        description:
          "Search a repository's files for a regular expression. Returns path:line: text " <>
            "for up to #{@max_matches} matches. Narrow with a glob.",
        schema: %{
          "type" => "object",
          "properties" => %{
            "repo" => %{"type" => "string"},
            "pattern" => %{"type" => "string", "description" => "a regular expression"},
            "glob" => %{"type" => "string", "description" => "optional glob to search within"}
          },
          "required" => ["repo", "pattern"]
        }
      }
    ]
  end

  @doc """
  Executes one tool call against the repositories in `repos` (by name).

  Always returns text: an error is a sentence the model can act on, never an
  exception that ends the task.
  """
  @spec call(String.t(), map(), [Repos.repo()]) :: String.t()
  def call(name, args, repos) when is_map(args) do
    with {:ok, repo} <- find(repos, args["repo"]) do
      run(name, args, repo)
    else
      {:error, text} -> text
    end
  rescue
    e -> "The tool failed: #{Exception.message(e)}"
  end

  defp find(repos, name) when is_binary(name) do
    case Enum.find(repos, &(&1.name == name)) do
      nil -> {:error, "No repository named #{inspect(name)}. Available: #{names(repos)}."}
      repo -> {:ok, repo}
    end
  end

  defp find(repos, _), do: {:error, "Say which repository: #{names(repos)}."}

  defp names(repos), do: Enum.map_join(repos, ", ", & &1.name)

  defp run("list_files", args, repo) do
    case files(repo, args["glob"]) do
      {:ok, []} ->
        "No files match."

      {:ok, files} ->
        files |> Enum.take(@max_files) |> Enum.join("\n") |> more(length(files), @max_files)

      {:error, text} ->
        text
    end
  end

  defp run("read_file", args, repo) do
    with path when is_binary(path) <- args["path"] || {:error, "read_file needs a path."},
         {:ok, content} <- Repos.read_file(repo, path, 4_000_000) |> explain(path) do
      start = max(int(args["start_line"], 1), 1)
      count = int(args["lines"], @default_window) |> max(1)

      lines = String.split(content, "\n")
      total = length(lines)

      window =
        lines
        |> Enum.drop(start - 1)
        |> Enum.take(count)
        |> Enum.with_index(start)
        |> Enum.map_join("\n", fn {line, n} -> "#{n}: #{line}" end)
        |> cut(@max_read_bytes)

      last = min(start + count - 1, total)

      tail =
        if last < total,
          do: "\n… #{total - last} more lines; read from start_line #{last + 1}.",
          else: ""

      "#{path} (lines #{start}–#{last} of #{total})\n#{window}#{tail}"
    else
      {:error, text} -> text
    end
  end

  defp run("grep", args, repo) do
    with pattern when is_binary(pattern) <- args["pattern"] || {:error, "grep needs a pattern."},
         {:ok, regex} <- Regex.compile(pattern) |> explain_regex(),
         {:ok, files} <- files(repo, args["glob"]) do
      matches =
        files
        |> Stream.flat_map(fn rel ->
          case Repos.read_file(repo, rel, 2_000_000) do
            {:ok, content} ->
              content
              |> String.split("\n")
              |> Stream.with_index(1)
              |> Stream.filter(fn {line, _} -> Regex.match?(regex, line) end)
              |> Stream.map(fn {line, n} -> "#{rel}:#{n}: #{String.slice(line, 0, 200)}" end)

            _ ->
              []
          end
        end)
        |> Enum.take(@max_matches + 1)

      case matches do
        [] ->
          "No matches for #{inspect(pattern)}."

        _ ->
          matches
          |> Enum.take(@max_matches)
          |> Enum.join("\n")
          |> more(length(matches), @max_matches)
      end
    else
      {:error, text} -> text
    end
  end

  defp run(other, _args, _repo), do: "No such tool: #{inspect(other)}."

  # Files under the clone, relative, text-ish, never inside .git or build output.
  defp files(repo, glob) do
    with {:ok, root} <- Repos.safe_path(repo, ".") do
      pattern = if is_binary(glob) and glob != "", do: glob, else: "**/*"

      case Repos.safe_path(repo, pattern) do
        {:ok, _} ->
          root
          |> Path.join(pattern)
          |> Path.wildcard(match_dot: false)
          |> Enum.filter(&File.regular?/1)
          |> Enum.map(&Path.relative_to(&1, root))
          |> Enum.reject(&skipped?/1)
          |> Enum.sort()
          |> then(&{:ok, &1})

        {:error, _} ->
          {:error, "That glob reaches outside the repository."}
      end
    end
  end

  defp skipped?(rel) do
    String.starts_with?(rel, [
      ".git/",
      "_build/",
      "deps/",
      "target/",
      "node_modules/",
      "priv/static/"
    ]) or
      String.ends_with?(rel, [
        ".so",
        ".png",
        ".jpg",
        ".gif",
        ".ico",
        ".woff",
        ".woff2",
        ".gldb",
        ".lock"
      ])
  end

  defp explain({:ok, _} = ok, _path), do: ok
  defp explain({:error, :enoent}, path), do: {:error, "No file at #{path}. Try list_files."}
  defp explain({:error, :eisdir}, path), do: {:error, "#{path} is a directory; list_files it."}

  defp explain({:error, {:path_escapes_repo, _}}, path),
    do: {:error, "#{path} is outside the repository."}

  defp explain({:error, {:absolute_path, _}}, path),
    do: {:error, "#{path} is absolute; use a path relative to the repository."}

  defp explain({:error, reason}, path),
    do: {:error, "Could not read #{path}: #{inspect(reason)}."}

  defp explain_regex({:ok, _} = ok), do: ok

  defp explain_regex({:error, {reason, at}}),
    do: {:error, "That pattern is not a valid regular expression (#{reason} at #{at})."}

  defp more(text, total, cap) when total > cap,
    do: text <> "\n… #{total - cap} more; narrow the glob."

  defp more(text, _total, _cap), do: text

  defp cut(text, max) when byte_size(text) > max,
    do: binary_part(text, 0, max) <> "\n… (cut; read a smaller window)"

  defp cut(text, _max), do: text

  defp int(v, _default) when is_integer(v), do: v

  defp int(v, default) when is_binary(v) do
    case Integer.parse(v) do
      {n, _} -> n
      :error -> default
    end
  end

  defp int(_, default), do: default
end
