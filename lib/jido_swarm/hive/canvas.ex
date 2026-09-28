defmodule JidoSwarm.Hive.Canvas do
  @moduledoc """
  The shared graph as something to look at.

  Everything the Hive knows is one `Jido.Context` graph, replicated between
  pods; this module turns it into what the operator's console draws — a delta
  summarised as a line in the ticker, later a node or edge on the canvas. It is
  pure over the graph's own vocabulary: the stamps `Jido.Context` puts on every
  entity (`_origin`, `_seq`, `_ts`, `_topic`) plus the Hive's labels and keys.

  Nothing here writes, and nothing here reads on a hot path: a delta is
  summarised from its own operations, without touching the graph.
  """

  alias Jido.Context.Delta
  alias JidoSwarm.Hive.Store

  # Keys whose repeated writes are the point — presence, leases, counters — so
  # a put is shown as an update rather than an arrival.
  @upsert_prefixes ~w(agent: claim: touch: endorse:)

  @max_ops_shown 3
  @caption_length 40

  # One colour per origin, in the order origins are first seen, with this
  # replica always first. Eight is more pods than a swarm runs; past that the
  # colours repeat and the legend still names them.
  @palette ~w(#2563eb #ea580c #16a34a #9333ea #0891b2 #db2777 #ca8a04 #64748b)

  # ===========================================================================
  # Who wrote the graph
  # ===========================================================================

  @doc """
  How much of this replica's graph each origin wrote.

  Counts nodes and edges by the `_origin` stamp `Jido.Context` puts on every
  entity, and the share of nodes written by someone other than `me` — the one
  number that says the memory is shared. Two aggregate queries, so cheap enough
  to run on a slow timer against the whole graph.
  """
  @spec authorship(String.t()) :: %{
          nodes: %{String.t() => non_neg_integer()},
          edges: %{String.t() => non_neg_integer()},
          total_nodes: non_neg_integer(),
          total_edges: non_neg_integer(),
          remote_share: float() | nil
        }
  def authorship(me) do
    nodes = count_by_origin("MATCH (n:Ctx) RETURN n._origin, count(n)")
    edges = count_by_origin("MATCH (:Ctx)-[r]->(:Ctx) RETURN r._origin, count(r)")
    total_nodes = nodes |> Map.values() |> Enum.sum()

    %{
      nodes: nodes,
      edges: edges,
      total_nodes: total_nodes,
      total_edges: edges |> Map.values() |> Enum.sum(),
      remote_share: if(total_nodes > 0, do: 1 - Map.get(nodes, me, 0) / total_nodes, else: nil)
    }
  end

  defp count_by_origin(cypher) do
    cypher
    |> Store.rows([:origin, :count])
    |> Enum.reject(&is_nil(&1.origin))
    |> Map.new(fn %{origin: origin, count: count} -> {origin, count} end)
  end

  @doc """
  A colour for every origin, this replica's first.

  Colours are assigned by position, so the same list of origins always gets
  the same colours — the console and the canvas agree because both call this.
  """
  @spec origin_colors([String.t()], String.t()) :: %{String.t() => String.t()}
  def origin_colors(origins, me) do
    [me | Enum.sort(origins)]
    |> Enum.uniq()
    |> Enum.with_index()
    |> Map.new(fn {origin, i} -> {origin, Enum.at(@palette, rem(i, length(@palette)))} end)
  end

  @doc """
  One line for a delta: what it did, in the Hive's words.

      +insight "parser is slow" → ABOUT task:t_1

  A put shows as `+kind "caption"`, or `~kind` for the entities that are
  meant to be rewritten (presence, claims, counters). A drop is `-key`, an
  edge is `→ TYPE target`. Past three operations the rest are counted.
  """
  @spec summarize(Delta.t()) :: String.t()
  def summarize(%Delta{ops: ops}) do
    {shown, rest} = Enum.split(ops, @max_ops_shown)

    shown
    |> Enum.map(&summarize_op/1)
    |> Kernel.++(if rest == [], do: [], else: ["+#{length(rest)} more"])
    |> Enum.join(" ")
  end

  defp summarize_op({:put_node, key, labels, props}) do
    verb = if String.starts_with?(key, @upsert_prefixes), do: "~", else: "+"

    case caption(props, nil) do
      nil -> verb <> kind(labels, key)
      caption -> ~s(#{verb}#{kind(labels, key)} "#{caption}")
    end
  end

  defp summarize_op({:drop_node, key}), do: "-" <> key
  defp summarize_op({:put_edge, _from, type, to, _props}), do: "→ #{type} #{to}"
  defp summarize_op({:drop_edge, _from, type, to}), do: "⨯ #{type} #{to}"

  @doc """
  The kind of an entity, for a person: the first label that is not the
  context's own, with the `Hive` prefix dropped and lowercased.

      iex> JidoSwarm.Hive.Canvas.kind(["Ctx", "HiveInsight"], "insight:i_1")
      "insight"

  A node with no label of its own is a placeholder — an edge endpoint that
  arrived before the node — and is named by its key's prefix.
  """
  @spec kind([String.t()], String.t()) :: String.t()
  def kind(labels, key) do
    case Enum.reject(labels, &(&1 in ["Ctx", "CtxTomb"])) do
      [label | _] -> label |> String.replace_prefix("Hive", "") |> String.downcase()
      [] -> key |> String.split(":", parts: 2) |> hd()
    end
  end

  @doc """
  A short caption for an entity from its properties, or `default`.

  Title before text before name: the most deliberate description wins, and a
  long text is cut so the ticker stays one line.
  """
  @spec caption(map(), term()) :: String.t() | term()
  def caption(props, default) do
    Enum.find_value(~w(title text name id uri value), default, fn field ->
      case Map.get(props, field) do
        value when is_binary(value) and value != "" -> truncate(value)
        _ -> nil
      end
    end)
  end

  defp truncate(text) do
    text = text |> String.replace(~r/\s+/, " ") |> String.trim()

    if String.length(text) > @caption_length,
      do: String.slice(text, 0, @caption_length - 1) <> "…",
      else: text
  end
end
