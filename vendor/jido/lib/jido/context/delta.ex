defmodule Jido.Context.Delta do
  @moduledoc """
  The unit of replication in a context mesh.

  A delta is a topic-tagged batch of graph operations, stamped with the origin
  that produced it and a Lamport clock. Agents exchange deltas rather than
  database bytes, which is what lets a mesh converge without a leader.

  ## Why deltas and not Glider's own replication

  Glider replicates by shipping byte ranges of the log file, and a compaction
  starts a new lineage (see `docs/REPLICATION.md` in the Glider tree). That is
  an excellent backup story and the wrong primitive here, for two reasons: it is
  single-writer — two processes appending to one file corrupt it — and the
  restored file is a point-in-time copy, not a follower that stays current.

  A mesh needs the opposite: every agent writes to its own graph, and every
  agent converges on what the others learned. So Jido replicates *semantic*
  operations, which are idempotent and commutative under the ordering below.

  ## Convergence

  Each operation carries the delta's `{seq, origin}` stamp, written onto the
  node or edge as `_seq` and `_origin`. An incoming operation is applied only
  when its stamp is greater than the stamp already recorded on that entity,
  comparing `seq` first and breaking ties on `origin`. That is last-writer-wins
  per entity, with a total order that every agent computes identically — so
  applying the same set of deltas in any order lands every graph in the same
  state.

  `origin` is a stable per-graph identity, not a hostname: two graphs in one VM
  are two origins.

  ## Shape

      %Jido.Context.Delta{
        id: "dlt_...",
        topic: "knowledge.papers",
        origin: "ctx_scout",
        seq: 12,
        ts: 1_758_000_000_000,
        ops: [
          {:put_node, "paper:attention", ["Paper"], %{"title" => "Attention Is All You Need"}},
          {:put_edge, "paper:attention", "CITES", "paper:rnn", %{}}
        ]
      }

  Operations:

  | Op | Meaning |
  |---|---|
  | `{:put_node, key, labels, props}` | upsert the node identified by `key` |
  | `{:drop_node, key}` | delete the node and its edges |
  | `{:put_edge, from_key, type, to_key, props}` | upsert the edge |
  | `{:drop_edge, from_key, type, to_key}` | delete the edge |
  """

  alias Jido.Context.Cypher

  @enforce_keys [:id, :topic, :origin, :seq, :ts, :ops]
  defstruct [:id, :topic, :origin, :seq, :ts, :ops]

  @type key :: String.t()
  @type op ::
          {:put_node, key(), [String.t()], map()}
          | {:drop_node, key()}
          | {:put_edge, key(), String.t(), key(), map()}
          | {:drop_edge, key(), String.t(), key()}

  @type t :: %__MODULE__{
          id: String.t(),
          topic: String.t(),
          origin: String.t(),
          seq: non_neg_integer(),
          ts: integer(),
          ops: [op()]
        }

  @doc """
  Builds a delta.

  Every operation is validated here rather than at apply time, so a malformed
  label or property key is rejected by the process that authored it instead of
  by every peer that receives it.
  """
  @spec new(String.t(), String.t(), non_neg_integer(), [op()], keyword()) :: t()
  def new(topic, origin, seq, ops, opts \\ []) do
    %__MODULE__{
      id: opts[:id] || "dlt_" <> Jido.Util.generate_id(),
      topic: validate_topic!(topic),
      origin: validate_origin!(origin),
      seq: seq,
      ts: opts[:ts] || System.system_time(:millisecond),
      ops: Enum.map(ops, &validate_op!/1)
    }
  end

  @doc """
  Compares two stamps, returning `:gt`, `:eq` or `:lt`.

  Sequence first, origin as the tiebreak. This is the total order that makes
  last-writer-wins deterministic across the mesh.

      iex> Jido.Context.Delta.compare_stamp({2, "a"}, {1, "z"})
      :gt

      iex> Jido.Context.Delta.compare_stamp({1, "b"}, {1, "a"})
      :gt
  """
  @spec compare_stamp({non_neg_integer(), String.t()}, {non_neg_integer(), String.t()}) ::
          :gt | :eq | :lt
  def compare_stamp({seq, origin}, {seq, origin}), do: :eq
  def compare_stamp({seq_a, _}, {seq_b, _}) when seq_a > seq_b, do: :gt
  def compare_stamp({seq_a, _}, {seq_b, _}) when seq_a < seq_b, do: :lt
  def compare_stamp({_, origin_a}, {_, origin_b}) when origin_a > origin_b, do: :gt
  def compare_stamp({_, _}, {_, _}), do: :lt

  @doc """
  Does `topic` match `pattern`?

  Patterns are dot-segmented with `*` matching one segment and `**` matching the
  rest, the same shape Jido signal paths use.

      iex> Jido.Context.Delta.topic_match?("knowledge.papers", "knowledge.*")
      true

      iex> Jido.Context.Delta.topic_match?("knowledge.papers.nlp", "knowledge.*")
      false

      iex> Jido.Context.Delta.topic_match?("knowledge.papers.nlp", "knowledge.**")
      true
  """
  @spec topic_match?(String.t(), String.t()) :: boolean()
  def topic_match?(topic, "**"), do: is_binary(topic)
  def topic_match?(topic, topic), do: true

  def topic_match?(topic, pattern) do
    match_segments(String.split(topic, "."), String.split(pattern, "."))
  end

  defp match_segments(_, ["**"]), do: true
  defp match_segments([], []), do: true
  defp match_segments([_ | rest_t], ["*" | rest_p]), do: match_segments(rest_t, rest_p)
  defp match_segments([seg | rest_t], [seg | rest_p]), do: match_segments(rest_t, rest_p)
  defp match_segments(_, _), do: false

  @doc """
  Encodes a delta as JSON, for transports that move bytes.

  Operations become tagged arrays — `["put_node", key, labels, props]` — which
  survives a round trip through any JSON implementation without needing atom
  keys on the far side.
  """
  @spec encode(t()) :: String.t()
  def encode(%__MODULE__{} = delta) do
    JSON.encode!(%{
      "id" => delta.id,
      "topic" => delta.topic,
      "origin" => delta.origin,
      "seq" => delta.seq,
      "ts" => delta.ts,
      "ops" => Enum.map(delta.ops, &encode_op/1)
    })
  end

  defp encode_op({:put_node, key, labels, props}), do: ["put_node", key, labels, props]
  defp encode_op({:drop_node, key}), do: ["drop_node", key]
  defp encode_op({:put_edge, from, type, to, props}), do: ["put_edge", from, type, to, props]
  defp encode_op({:drop_edge, from, type, to}), do: ["drop_edge", from, type, to]

  @doc """
  Decodes a delta produced by `encode/1`.

  Returns `{:error, reason}` rather than raising: this parses bytes that arrived
  over a network, where malformed input is an expected condition and must not
  take down the poller that read it.
  """
  @spec decode(String.t()) :: {:ok, t()} | {:error, term()}
  def decode(json) when is_binary(json) do
    with {:ok, map} <- JSON.decode(json),
         {:ok, delta} <- from_map(map) do
      {:ok, delta}
    else
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp from_map(%{
         "id" => id,
         "topic" => topic,
         "origin" => origin,
         "seq" => seq,
         "ts" => ts,
         "ops" => ops
       })
       when is_binary(id) and is_binary(topic) and is_binary(origin) and is_integer(seq) and
              is_integer(ts) and is_list(ops) do
    {:ok,
     %__MODULE__{
       id: id,
       topic: topic,
       origin: origin,
       seq: seq,
       ts: ts,
       ops: Enum.map(ops, &decode_op!/1)
     }}
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp from_map(_), do: {:error, :malformed_delta}

  defp decode_op!(["put_node", key, labels, props]),
    do: validate_op!({:put_node, key, labels, props})

  defp decode_op!(["drop_node", key]), do: validate_op!({:drop_node, key})

  defp decode_op!(["put_edge", from, type, to, props]),
    do: validate_op!({:put_edge, from, type, to, props})

  defp decode_op!(["drop_edge", from, type, to]), do: validate_op!({:drop_edge, from, type, to})
  defp decode_op!(other), do: raise(ArgumentError, "unknown delta op: #{inspect(other)}")

  # Topics name object-storage prefixes and signal paths, so they are held to
  # the same shape as an identifier segment plus dots.
  defp validate_topic!(topic) when is_binary(topic) do
    if Regex.match?(~r/^[A-Za-z0-9_\-]+(\.[A-Za-z0-9_\-]+)*$/, topic) do
      topic
    else
      raise ArgumentError,
            "invalid topic: #{inspect(topic)} (expected dot-separated [A-Za-z0-9_-] segments)"
    end
  end

  # An origin becomes a path segment in the topic log, so it is held to the
  # same shape as a topic segment.
  defp validate_origin!(origin) when is_binary(origin) do
    if Regex.match?(~r/^[A-Za-z0-9_\-]+$/, origin) do
      origin
    else
      raise ArgumentError,
            "invalid origin: #{inspect(origin)} (expected [A-Za-z0-9_-]+)"
    end
  end

  defp validate_op!({:put_node, key, labels, props} = op)
       when is_binary(key) and is_list(labels) do
    Enum.each(labels, &Cypher.identifier!/1)
    validate_props!(props)
    op
  end

  defp validate_op!({:drop_node, key} = op) when is_binary(key), do: op

  defp validate_op!({:put_edge, from, type, to, props} = op)
       when is_binary(from) and is_binary(to) do
    Cypher.identifier!(type)
    validate_props!(props)
    op
  end

  defp validate_op!({:drop_edge, from, type, to} = op) when is_binary(from) and is_binary(to) do
    Cypher.identifier!(type)
    op
  end

  defp validate_op!(op), do: raise(ArgumentError, "invalid delta op: #{inspect(op)}")

  # Leading-underscore keys are reserved: `Jido.Context.Graph` writes `_key`,
  # `_seq`, `_origin`, `_topic` and `_ts` onto every entity, and a user property
  # that collided with one of them would corrupt the ordering the mesh relies
  # on. Deltas carry user properties only; the stamp lives on the delta.
  defp validate_props!(props) when is_map(props) do
    Enum.each(props, fn {k, _v} ->
      name = Cypher.identifier!(k)

      if String.starts_with?(name, "_") do
        raise ArgumentError,
              "property #{inspect(name)} is reserved: leading-underscore keys are written by " <>
                "Jido.Context.Graph to carry the replication stamp"
      end
    end)

    props
  end

  defp validate_props!(props),
    do: raise(ArgumentError, "props must be a map, got: #{inspect(props)}")
end
