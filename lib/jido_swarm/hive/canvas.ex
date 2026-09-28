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

  # The canvas draws the newest entities and stops: past a few hundred nodes a
  # force layout is a hairball, and the operator wants to see what is
  # happening, not everything that ever did. Edges are read wider than nodes
  # because most of them will join two nodes that made the cut.
  @cap 300
  @edge_read_cap 1_200
  @neighbour_cap 40

  @type node_json :: %{
          key: String.t(),
          kind: String.t(),
          labels: [String.t()],
          caption: String.t(),
          origin: String.t() | nil,
          seq: non_neg_integer() | nil,
          ts: integer() | nil,
          topic: String.t() | nil,
          heat: float(),
          ghost: boolean()
        }

  @type edge_json :: %{
          id: String.t(),
          from: String.t(),
          type: String.t(),
          to: String.t(),
          origin: String.t() | nil,
          seq: non_neg_integer() | nil,
          ts: integer() | nil
        }

  # ===========================================================================
  # What the canvas draws
  # ===========================================================================

  @doc """
  The graph as the canvas first sees it: the newest #{@cap} entities and the
  edges between them, with the heat on each task.

  `truncated` says the graph holds more than was sent; `total` is how many.
  """
  @spec snapshot(keyword()) :: %{
          nodes: [node_json()],
          edges: [edge_json()],
          truncated: boolean(),
          total: non_neg_integer()
        }
  def snapshot(opts \\ []) do
    cap = Keyword.get(opts, :cap, @cap)
    heat = heat()

    nodes =
      "MATCH (n:Ctx) RETURN n, n._ts AS ts ORDER BY ts DESC LIMIT #{cap}"
      |> Store.rows([:node, :ts])
      |> Enum.map(&entity(&1.node, heat))

    keys = MapSet.new(nodes, & &1.key)

    edges =
      ("MATCH (a:Ctx)-[r]->(b:Ctx) RETURN a._key, type(r), b._key, r._origin, r._seq, r._ts " <>
         "ORDER BY r._ts DESC LIMIT #{@edge_read_cap}")
      |> Store.rows([:from, :type, :to, :origin, :seq, :ts])
      |> Enum.filter(&(MapSet.member?(keys, &1.from) and MapSet.member?(keys, &1.to)))
      |> Enum.map(&edge/1)

    total = "MATCH (n:Ctx) RETURN count(n)" |> Store.rows([:count]) |> count()

    %{nodes: nodes, edges: edges, truncated: total > length(nodes), total: total}
  end

  @doc """
  One entity as the canvas draws it.

  Takes what Glider returns for `RETURN n` — a struct with `labels` and
  `props` — or a map of the same shape. The stamps become the node's origin,
  sequence and time; a node with no label of its own is a *ghost*, the
  placeholder `Jido.Context` creates for an edge whose end has not arrived.
  """
  @spec entity(map(), map()) :: node_json()
  def entity(entity, heat \\ %{}) do
    labels = Map.get(entity, :labels) || Map.get(entity, "labels") || []
    props = Map.get(entity, :props) || Map.get(entity, "props") || %{}
    key = props["_key"]

    %{
      key: key,
      kind: kind(labels, key),
      labels: Enum.reject(labels, &(&1 in ["Ctx", "CtxTomb"])),
      caption: caption(props, key),
      origin: props["_origin"],
      seq: props["_seq"],
      ts: props["_ts"],
      topic: props["_topic"],
      heat: Map.get(heat, key, 0.0),
      ghost: Enum.reject(labels, &(&1 in ["Ctx", "CtxTomb"])) == []
    }
  end

  @doc """
  A delta as canvas operations, in order.

  The canvas applies these without asking the graph: a put becomes a node or
  edge (an edge whose end it has not seen gets a ghost, as the graph itself
  does), a drop fades one out. What the delta carries is all the canvas
  needs, so a write on another pod is on screen the moment it arrives here.
  """
  @spec delta_ops(Delta.t()) :: [map()]
  def delta_ops(%Delta{} = delta) do
    stamp = %{
      "_origin" => delta.origin,
      "_seq" => delta.seq,
      "_ts" => delta.ts,
      "_topic" => delta.topic
    }

    Enum.map(delta.ops, fn
      {:put_node, key, labels, props} ->
        props = props |> Map.merge(stamp) |> Map.put("_key", key)
        %{op: "put_node", node: entity(%{labels: labels, props: props})}

      {:drop_node, key} ->
        %{op: "drop_node", key: key}

      {:put_edge, from, type, to, _props} ->
        %{
          op: "put_edge",
          edge:
            edge(%{
              from: from,
              type: type,
              to: to,
              origin: delta.origin,
              seq: delta.seq,
              ts: delta.ts
            })
        }

      {:drop_edge, from, type, to} ->
        %{op: "drop_edge", id: edge_id(from, type, to)}
    end)
  end

  @doc """
  One entity in full, for the drawer: its own properties, its stamp, and who
  it is connected to. `nil` if the key is not in the graph.
  """
  @spec detail(String.t()) :: map() | nil
  def detail(key) do
    case Store.rows("MATCH (n:Ctx #{key_match(key)}) RETURN n", [:node]) do
      [%{node: entity}] ->
        node = entity(entity, heat())

        props =
          entity
          |> Map.get(:props, %{})
          |> Enum.reject(fn {k, _} -> String.starts_with?(k, "_") end)
          |> Map.new()

        %{
          node: node,
          props: props,
          stamp: %{
            origin: node.origin,
            seq: node.seq,
            ts: node.ts,
            topic: node.topic,
            age_ms: node.ts && Store.now() - node.ts
          },
          neighbours: neighbour_rows(key)
        }

      _ ->
        nil
    end
  end

  @doc """
  What is around a key, to add to the canvas on request: its neighbours and
  the edges to them, both ways, up to #{@neighbour_cap} of each direction.
  """
  @spec neighbours(String.t()) :: %{nodes: [node_json()], edges: [edge_json()]}
  def neighbours(key) do
    heat = heat()

    out =
      Store.rows(
        "MATCH (n:Ctx #{key_match(key)})-[r]->(m:Ctx) RETURN m, type(r), r._origin, r._seq, r._ts LIMIT #{@neighbour_cap}",
        [:node, :type, :origin, :seq, :ts]
      )
      |> Enum.map(
        &{entity(&1.node, heat),
         %{
           from: key,
           type: &1.type,
           to: &1.node.props["_key"],
           origin: &1.origin,
           seq: &1.seq,
           ts: &1.ts
         }}
      )

    in_ =
      Store.rows(
        "MATCH (n:Ctx #{key_match(key)})<-[r]-(m:Ctx) RETURN m, type(r), r._origin, r._seq, r._ts LIMIT #{@neighbour_cap}",
        [:node, :type, :origin, :seq, :ts]
      )
      |> Enum.map(
        &{entity(&1.node, heat),
         %{
           from: &1.node.props["_key"],
           type: &1.type,
           to: key,
           origin: &1.origin,
           seq: &1.seq,
           ts: &1.ts
         }}
      )

    pairs = out ++ in_

    %{
      nodes: pairs |> Enum.map(&elem(&1, 0)) |> Enum.uniq_by(& &1.key),
      edges: pairs |> Enum.map(&edge(elem(&1, 1))) |> Enum.uniq_by(& &1.id)
    }
  end

  @doc "Entities by key, as the canvas draws them — for re-reading what changed."
  @spec nodes([String.t()]) :: [node_json()]
  def nodes([]), do: []

  def nodes(keys) do
    heat = heat()
    list = Enum.map_join(keys, ", ", &Store.lit/1)

    "MATCH (n:Ctx) WHERE n._key IN [#{list}] RETURN n"
    |> Store.rows([:node])
    |> Enum.map(&entity(&1.node, heat))
  end

  defp neighbour_rows(key) do
    out =
      Store.rows(
        "MATCH (n:Ctx #{key_match(key)})-[r]->(m:Ctx) RETURN type(r), m LIMIT #{@neighbour_cap}",
        [:type, :node]
      )
      |> Enum.map(&neighbour(&1, "out"))

    in_ =
      Store.rows(
        "MATCH (n:Ctx #{key_match(key)})<-[r]-(m:Ctx) RETURN type(r), m LIMIT #{@neighbour_cap}",
        [:type, :node]
      )
      |> Enum.map(&neighbour(&1, "in"))

    out ++ in_
  end

  defp neighbour(%{type: type, node: entity}, dir) do
    n = entity(entity)
    %{key: n.key, type: type, dir: dir, kind: n.kind, caption: n.caption, origin: n.origin}
  end

  defp edge(%{from: from, type: type, to: to} = row) do
    %{
      id: edge_id(from, type, to),
      from: from,
      type: type,
      to: to,
      origin: row[:origin],
      seq: row[:seq],
      ts: row[:ts]
    }
  end

  defp edge_id(from, type, to), do: "#{from}|#{type}|#{to}"

  defp key_match(key), do: "{_key: #{Store.lit(key)}}"

  defp count([%{count: n}]) when is_integer(n), do: n
  defp count(_), do: 0

  defp heat do
    JidoSwarm.Hive.Memory.heat()
  rescue
    _ -> %{}
  end

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
