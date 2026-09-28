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

  # Keys whose repeated writes are the point — presence, leases, counters — so
  # a put is shown as an update rather than an arrival.
  @upsert_prefixes ~w(agent: claim: touch: endorse:)

  @max_ops_shown 3
  @caption_length 40

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
