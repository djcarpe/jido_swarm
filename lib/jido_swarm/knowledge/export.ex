defmodule JidoSwarm.Knowledge.Export do
  @moduledoc """
  The graph as a file the operator can take away.

  Everything a pod knows lives in one Glider database, and Glider's JSON
  Lines export is its portable form: one object per node and per edge, ids
  local to the file, labels and properties as written — including the mesh
  stamps (`_key`, `_origin`, `_seq`, `_topic`, `_ts`), which is what makes a
  download of one replica a faithful record of what the whole swarm wrote.

  A scope cuts the file down by the topic each entity was published on:

  | Scope | Keeps |
  |---|---|
  | `:graph` | everything, exactly as Glider exports it |
  | `:knowledge` | `knowledge.**` — repositories, findings, proposals, attempts |
  | `:context` | `context.**` — the operator conversation |
  | `:hive` | `hive.**` — the board, claims, agents, memory, signals |

  A filtered file keeps an edge only when both of its ends are kept, so it
  always imports cleanly: `Jido.Context.import/2`, `Glider.import_jsonl/2`,
  or `glider <db> import` all read it back.

  ## Why JSON Lines and not the database file

  The `.gldb` is a paged file with a write-ahead log beside it, and the graph
  process is writing to both while the swarm runs; a copy taken underneath it
  is not guaranteed to open. The export is produced by the graph itself, in
  one call, and is engine-independent — the same form the S3 snapshots take.
  """

  alias Jido.Context

  @scopes [
    graph: %{label: "everything", prefix: nil},
    knowledge: %{label: "knowledge", prefix: "knowledge."},
    context: %{label: "conversation", prefix: "context."},
    hive: %{label: "the Hive", prefix: "hive."}
  ]

  @doc "The scopes a download can ask for, in the order the console lists them."
  @spec scopes() :: [{atom(), %{label: String.t(), prefix: String.t() | nil}}]
  def scopes, do: @scopes

  @doc "The scope atom for a name from a URL, or nil."
  @spec scope(String.t()) :: atom() | nil
  def scope(name) when is_binary(name) do
    Enum.find_value(@scopes, fn {scope, _} -> if Atom.to_string(scope) == name, do: scope end)
  end

  @doc """
  The export for a scope, as JSON Lines, with how much it holds.

  `:graph` is Glider's own export untouched. Any other scope is that export
  with entities outside the topic prefix removed, edge by edge.
  """
  @spec jsonl(atom(), atom()) ::
          {:ok, iodata(), %{nodes: non_neg_integer(), edges: non_neg_integer()}}
          | {:error, term()}
  def jsonl(scope, graph \\ JidoSwarm.graph()) do
    with {:ok, %{prefix: prefix}} <- Keyword.fetch(@scopes, scope) |> ok_or(:unknown_scope),
         {:ok, all} <- Context.export(graph) do
      lines = String.split(all, "\n", trim: true)

      case prefix do
        nil ->
          {:ok, all, count(lines)}

        prefix ->
          {out, counts} = filter(lines, prefix)
          {:ok, out, counts}
      end
    end
  end

  @doc "A file name that says which replica, which scope, and when."
  @spec filename(atom(), String.t()) :: String.t()
  def filename(scope, origin) do
    stamp = DateTime.utc_now() |> Calendar.strftime("%Y%m%d-%H%M%S")
    "swarm-#{origin}-#{scope}-#{stamp}.jsonl"
  end

  # Two passes: which nodes stay decides which edges can.
  defp filter(lines, prefix) do
    decoded = Enum.map(lines, &JSON.decode!/1)

    nodes =
      Enum.filter(decoded, fn
        %{"type" => "node", "props" => props} ->
          String.starts_with?(props["_topic"] || "", prefix)

        _ ->
          false
      end)

    kept = MapSet.new(nodes, & &1["id"])

    edges =
      Enum.filter(decoded, fn
        %{"type" => "edge", "from" => from, "to" => to} ->
          MapSet.member?(kept, from) and MapSet.member?(kept, to)

        _ ->
          false
      end)

    out = Enum.map(nodes ++ edges, &[JSON.encode!(&1), "\n"])
    {out, %{nodes: length(nodes), edges: length(edges)}}
  end

  defp count(lines) do
    Enum.reduce(lines, %{nodes: 0, edges: 0}, fn line, acc ->
      cond do
        String.starts_with?(line, ~s({"type":"node")) -> %{acc | nodes: acc.nodes + 1}
        String.starts_with?(line, ~s({"type":"edge")) -> %{acc | edges: acc.edges + 1}
        true -> acc
      end
    end)
  end

  defp ok_or({:ok, _} = ok, _), do: ok
  defp ok_or(:error, reason), do: {:error, reason}
end
