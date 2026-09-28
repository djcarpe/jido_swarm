defmodule JidoSwarm.Hive.Store do
  @moduledoc """
  The Hive's vocabulary over `Jido.Context`: labels, keys, topics, and the
  few read/write helpers every other Hive module goes through.

  ## Why facets are separate entities

  `Jido.Context` converges by last-writer-wins *per entity*: a newer write
  merges its properties, but an older write to the same entity is dropped
  whole. Two agents updating different properties of one task at the same
  moment would therefore lose one update. So anything written independently by
  different agents is its own entity:

  | Entity | Written by | Why separate |
  |---|---|---|
  | `task:<id>` | its creator | the description rarely changes |
  | `claim:<task>` | whoever holds or last held the task | the lifecycle; LWW picks one winner among racing claimers |
  | `agent:<id>` | that agent only | presence and skills |
  | `touch:<task>:<agent>` | that agent only | interest, summed over agents (a grow-only counter) |
  | `endorse:<insight>:<agent>` | that agent only | votes, summed over agents |
  | notes, insights, questions, answers, decisions, artifacts, messages | their author | append-only, never edited |

  Nothing here is ever updated by two agents, except the claim, where
  converging on exactly one writer is the point.
  """

  alias Jido.Context
  alias Jido.Context.Cypher

  @topics %{
    board: "hive.board",
    claims: "hive.claims",
    agents: "hive.agents",
    memory: "hive.memory",
    signals: "hive.signals"
  }

  @doc "The topic a kind of Hive write is published on."
  @spec topic(atom()) :: String.t()
  def topic(kind), do: Map.fetch!(@topics, kind)

  @doc "Every Hive topic; subscribe to `hive.**` for all of them."
  @spec topics() :: [String.t()]
  def topics, do: Map.values(@topics)

  @doc "The graph the Hive lives in."
  @spec graph() :: atom()
  def graph, do: Application.get_env(:jido_swarm, :hive_graph, JidoSwarm.graph())

  @doc "Milliseconds since the epoch."
  @spec now() :: integer()
  def now, do: System.system_time(:millisecond)

  @doc "A fresh, sortable-enough id with a readable prefix."
  @spec new_id(String.t()) :: String.t()
  def new_id(prefix) do
    t = now() |> Integer.to_string(36) |> String.downcase()

    prefix <>
      "_" <> t <> (:crypto.strong_rand_bytes(4) |> Base.encode32(case: :lower, padding: false))
  end

  # ===========================================================================
  # Writes
  # ===========================================================================

  @doc "Upserts one node, optionally with edges, in a single delta."
  @spec put(String.t(), [String.t()], map(), [{String.t(), String.t(), map()}], atom()) ::
          :ok | {:error, term()}
  def put(key, labels, props, edges \\ [], topic_kind) do
    ops =
      [{:put_node, key, labels, stringify(props)}] ++
        Enum.map(edges, fn {type, to, eprops} -> {:put_edge, key, type, to, stringify(eprops)} end)

    case Context.commit(graph(), ops, topic: topic(topic_kind)) do
      {:ok, _} -> :ok
      {:error, _} = e -> e
    end
  end

  @doc "Adds one edge."
  @spec relate(String.t(), String.t(), String.t(), map(), atom()) :: :ok | {:error, term()}
  def relate(from, type, to, props, topic_kind) do
    case Context.commit(graph(), [{:put_edge, from, type, to, stringify(props)}],
           topic: topic(topic_kind)
         ) do
      {:ok, _} -> :ok
      {:error, _} = e -> e
    end
  end

  # ===========================================================================
  # Reads
  # ===========================================================================

  @doc """
  Runs a query and zips each row with `fields`. Read errors read as empty: a
  board that cannot be read is an empty board, never a crash in an agent loop.
  """
  @spec rows(String.t(), [atom()]) :: [map()]
  def rows(cypher, fields) do
    case Context.query(graph(), cypher) do
      {:ok, %{rows: rows}} -> Enum.map(rows, fn row -> fields |> Enum.zip(row) |> Map.new() end)
      _ -> []
    end
  end

  @doc "Every node with `label`, as maps of the listed properties plus `:key`."
  @spec all(String.t(), [String.t()]) :: [map()]
  def all(label, props) do
    Cypher.identifier!(label)
    fields = [:key | Enum.map(props, &String.to_atom/1)]
    ret = Enum.map_join(["_key" | props], ", ", &("n." <> Cypher.identifier!(&1)))
    rows("MATCH (n:#{label}) RETURN #{ret}", fields)
  end

  @doc "Edges of `type` as `{from_key, to_key, props}` maps."
  @spec edges(String.t(), [String.t()]) :: [map()]
  def edges(type, props \\ []) do
    Cypher.identifier!(type)
    fields = [:from, :to | Enum.map(props, &String.to_atom/1)]
    ret = Enum.map_join(props, "", &(", r." <> Cypher.identifier!(&1)))
    rows("MATCH (a)-[r:#{type}]->(b) RETURN a._key, b._key#{ret}", fields)
  end

  @doc "One node's properties by key, or nil."
  @spec get(String.t()) :: map() | nil
  def get(key) do
    case Context.fetch(graph(), key) do
      {:ok, %{props: props}} -> props
      {:ok, map} when is_map(map) -> Map.get(map, :props, map)
      _ -> nil
    end
  end

  @doc "A Cypher literal for any term."
  @spec lit(term()) :: String.t()
  def lit(v), do: Cypher.encode_value(v)

  # Properties as string-keyed maps; lists and maps of scalars are kept, other
  # terms are stringified so a bad value cannot reach the engine.
  defp stringify(map) do
    Map.new(map, fn {k, v} -> {to_string(k), clean(v)} end)
  end

  defp clean(v) when is_binary(v) or is_number(v) or is_boolean(v) or is_nil(v), do: v
  defp clean(v) when is_atom(v), do: Atom.to_string(v)
  defp clean(v) when is_list(v), do: Enum.map(v, &clean/1)
  defp clean(v), do: inspect(v)
end
