defmodule Jido.Context.Store.Disk do
  @moduledoc """
  A `Jido.Context.Store` backed by a directory tree.

  Object keys become paths under `:path`, so `mesh/topics/knowledge/000012.json`
  is a real file you can `cat`. Writes go to a temporary file and are renamed
  into place, so a reader never sees a half-written snapshot.

  ## Options

  * `:path` — base directory (required). Created on demand.

  ## Note on "on disk"

  A graph configured with `store: {:disk, ...}` is durable in two independent
  ways, and it is worth keeping them apart:

  * The **graph file** — `Jido.Context.Graph` opens Glider against a `.gldb`
    file, which is a write-ahead log and the persistent form at once. That is
    the durability that matters for restart.
  * The **snapshot** — this store, holding a JSON Lines dump. That is the
    durability that matters for *moving* a graph: it is engine-independent and
    is what gets shipped to S3.

  ## Key safety

  Keys are validated before touching the filesystem: segments of
  `[A-Za-z0-9._-]` separated by `/`, and no segment may be `.` or `..`. A key
  is often derived from a topic name, which can reach this code from a peer, so
  a traversal has to be impossible rather than unlikely.
  """

  @behaviour Jido.Context.Store

  @segment ~r/^[A-Za-z0-9._\-]+$/

  @impl true
  def get(key, opts) do
    with {:ok, path} <- resolve(key, opts) do
      case File.read(path) do
        {:ok, body} -> {:ok, body}
        {:error, :enoent} -> :not_found
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @impl true
  def put(key, body, opts) when is_binary(body) do
    with {:ok, path} <- resolve(key, opts),
         :ok <- path |> Path.dirname() |> File.mkdir_p() do
      tmp = path <> ".tmp-" <> Integer.to_string(System.unique_integer([:positive]))

      with :ok <- File.write(tmp, body),
           :ok <- File.rename(tmp, path) do
        :ok
      else
        {:error, reason} ->
          File.rm(tmp)
          {:error, reason}
      end
    end
  end

  @impl true
  def delete(key, opts) do
    with {:ok, path} <- resolve(key, opts) do
      case File.rm(path) do
        :ok -> :ok
        {:error, :enoent} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @impl true
  def list(prefix, opts) do
    base = Keyword.fetch!(opts, :path)
    after_key = opts[:after]
    limit = opts[:limit]

    keys =
      base
      |> walk()
      |> Enum.map(&Path.relative_to(&1, base))
      |> Enum.filter(&String.starts_with?(&1, prefix))
      |> Enum.filter(fn key -> is_nil(after_key) or key > after_key end)
      |> Enum.sort()

    {:ok, if(limit, do: Enum.take(keys, limit), else: keys)}
  end

  # Depth-first walk. Partial writes (`.tmp-*`) are skipped so a concurrent
  # `put/3` cannot surface a key that is about to change name.
  defp walk(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        Enum.flat_map(entries, fn entry ->
          path = Path.join(dir, entry)

          cond do
            File.dir?(path) -> walk(path)
            String.contains?(entry, ".tmp-") -> []
            true -> [path]
          end
        end)

      {:error, _} ->
        []
    end
  end

  defp resolve(key, opts) do
    base = Keyword.fetch!(opts, :path)

    with :ok <- validate_key(key) do
      {:ok, Path.join([base | String.split(key, "/")])}
    end
  end

  defp validate_key(key) when is_binary(key) do
    segments = String.split(key, "/")

    # `..` matches @segment, so it is excluded explicitly — this is the check
    # that makes a traversal impossible rather than merely unlikely.
    if segments != [] and Enum.all?(segments, &safe_segment?/1) do
      :ok
    else
      {:error, {:invalid_key, key}}
    end
  end

  defp validate_key(key), do: {:error, {:invalid_key, key}}

  defp safe_segment?(segment) do
    segment not in [".", ".."] and Regex.match?(@segment, segment)
  end
end
