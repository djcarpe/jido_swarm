defmodule Jido.Context.Mesh.Log do
  @moduledoc """
  A `Jido.Context.Mesh.Transport` that streams deltas through a
  `Jido.Context.Store` — memory, disk, or S3.

  Publishing writes one immutable object per delta. A poller on every other
  agent lists what is new and applies it. That is the whole protocol: no broker,
  no direct connectivity between agents, and no coordinator. An agent that
  starts a week later reads the same log and converges.

      {:log, store: {:s3, bucket: "graphs", prefix: "research"}, interval: 1_000}

  ## Layout

      members/<topic>/<origin>            a marker naming one participant
      topics/<topic>/<origin>/<seq>.json  one delta, written once

  ## Why the log is partitioned by origin

  The obvious design — one flat, time-ordered prefix per topic, tailed with
  S3's `start-after` — has a race that loses data silently. Keys would have to
  sort in write order, and they do not: agent A can write sequence 5 after agent
  B has written 9, and a poller that already passed 9 never lists 5 again. The
  delta is in the bucket and no one ever reads it.

  Partitioning by origin removes the assumption instead of narrowing it. Each
  origin's own sequence numbers *are* monotonic, so a per-origin cursor is
  exact, and no clock anywhere has to agree with any other.

  Participants are discovered from the `members/` prefix, which holds one small
  object per origin rather than one per delta — so a poll costs a listing
  proportional to the number of agents, not to the size of the log.

  ## Options

  * `:store` — required. Any `Jido.Context.Store` spec.
  * `:interval` — poll period in ms. Default 1000.
  * `:catch_up` — on start, `:all` replays the whole log, `:new` (the default)
    starts from what is already there without replaying it. Use `:all` for an
    agent that must inherit the mesh's history.
  * `:retain` — how many deltas to keep per origin. `:infinity` (default) keeps
    them all; an integer trims older objects after each publish.
  """

  use GenServer

  require Logger

  @behaviour Jido.Context.Mesh.Transport

  alias Jido.Context.Delta
  alias Jido.Context.Mesh
  alias Jido.Context.Store

  # Keys must sort lexicographically in sequence order within an origin, so the
  # number is fixed-width. 20 digits covers the full 64-bit range.
  @seq_width 20
  @default_interval 1_000

  @impl Jido.Context.Mesh.Transport
  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.fetch!(opts, :mesh)},
      start: {__MODULE__, :start_link, [opts]},
      type: :worker
    }
  end

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl Jido.Context.Mesh.Transport
  def publish(%Delta{} = delta, opts) do
    store = opts |> Keyword.fetch!(:store) |> Store.normalize()

    with :ok <- Store.put(store, delta_key(delta), Delta.encode(delta)),
         :ok <- announce(store, delta) do
      maybe_trim(store, delta, opts[:retain])
    end
  end

  # The member marker is what lets other agents discover this origin without
  # listing the whole log. It is rewritten on every publish, which is one small
  # PUT and keeps `last_seq` usefully current for operators looking at the
  # bucket.
  defp announce(store, delta) do
    body =
      JSON.encode!(%{
        "origin" => delta.origin,
        "topic" => delta.topic,
        "last_seq" => delta.seq,
        "updated_at" => delta.ts
      })

    Store.put(store, member_key(delta.topic, delta.origin), body)
  end

  defp maybe_trim(_store, _delta, nil), do: :ok
  defp maybe_trim(_store, _delta, :infinity), do: :ok

  defp maybe_trim(store, delta, retain) when is_integer(retain) and retain > 0 do
    prefix = origin_prefix(delta.topic, delta.origin)

    case Store.list(store, prefix) do
      {:ok, keys} when length(keys) > retain ->
        keys
        |> Enum.sort()
        |> Enum.drop(-retain)
        |> Enum.each(&Store.delete(store, &1))

        :ok

      {:ok, _} ->
        :ok

      {:error, reason} ->
        # Trimming is housekeeping; failing it must not fail the publish that
        # already succeeded.
        Logger.warning("jido context log: could not trim #{prefix}: #{inspect(reason)}")
        :ok
    end
  end

  # ===========================================================================
  # Poller
  # ===========================================================================

  @impl GenServer
  def init(opts) do
    state = %{
      mesh: Keyword.fetch!(opts, :mesh),
      store: opts |> Keyword.fetch!(:store) |> Store.normalize(),
      topics: Keyword.get(opts, :topics, ["**"]),
      interval: Keyword.get(opts, :interval, @default_interval),
      catch_up: Keyword.get(opts, :catch_up, :new),
      cursors: %{}
    }

    # `catch_up: :new` fast-forwards every cursor to the end of the log before
    # the first poll, so a fresh agent is not flooded with history it did not
    # ask for.
    state = if state.catch_up == :new, do: fast_forward(state), else: state

    schedule(state)
    {:ok, state}
  end

  @impl GenServer
  def handle_info(:poll, state) do
    state = poll(state)
    schedule(state)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @doc """
  Runs one poll pass synchronously and returns once its deltas are delivered.

  Polling is otherwise on a timer, which a test would have to sleep through.
  """
  @spec poll_now(pid(), timeout()) :: :ok
  def poll_now(pid, timeout \\ 15_000), do: GenServer.call(pid, :poll_now, timeout)

  @impl GenServer
  def handle_call(:poll_now, _from, state) do
    state = poll(state)
    Mesh.sync(state.mesh)
    {:reply, :ok, state}
  end

  defp schedule(state), do: Process.send_after(self(), :poll, state.interval)

  defp poll(state) do
    Enum.reduce(known_topics(state), state, &poll_topic(&2, &1))
  end

  # A poller lists `members/` to find the topics and origins actually in play.
  # Patterns like "knowledge.**" cannot be turned into a listing prefix, so the
  # member markers are listed once and filtered against the patterns.
  defp known_topics(state) do
    case Store.list(state.store, "members/") do
      {:ok, keys} ->
        keys
        |> Enum.map(&topic_from_member_key/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()
        |> Enum.filter(fn topic ->
          Enum.any?(state.topics, &Delta.topic_match?(topic, &1))
        end)

      {:error, reason} ->
        Logger.warning("jido context log: could not list members: #{inspect(reason)}")
        []
    end
  end

  defp poll_topic(state, topic) do
    Enum.reduce(origins(state, topic), state, fn origin, acc ->
      poll_origin(acc, topic, origin)
    end)
  end

  defp origins(state, topic) do
    case Store.list(state.store, member_prefix(topic)) do
      {:ok, keys} -> Enum.map(keys, &Path.basename/1)
      {:error, _} -> []
    end
  end

  defp poll_origin(state, topic, origin) do
    prefix = origin_prefix(topic, origin)
    cursor = state.cursors[{topic, origin}]

    case Store.list(state.store, prefix, after: cursor) do
      {:ok, []} ->
        state

      {:ok, keys} ->
        Enum.reduce(keys, state, fn key, acc ->
          case fetch_and_deliver(acc, key) do
            :ok -> put_in(acc.cursors[{topic, origin}], key)
            # A key that cannot be read stays uncommitted, so the next pass
            # retries it rather than stepping over a gap.
            :error -> acc
          end
        end)

      {:error, reason} ->
        Logger.warning("jido context log: could not list #{prefix}: #{inspect(reason)}")
        state
    end
  end

  defp fetch_and_deliver(state, key) do
    case Store.get(state.store, key) do
      {:ok, body} ->
        case Delta.decode(body) do
          {:ok, delta} ->
            Mesh.deliver(state.mesh, delta)
            :ok

          {:error, reason} ->
            # Malformed bytes will not become well-formed on a retry, so the
            # cursor advances past them rather than wedging the poller.
            Logger.warning("jido context log: undecodable delta at #{key}: #{inspect(reason)}")
            :ok
        end

      :not_found ->
        :ok

      {:error, reason} ->
        Logger.warning("jido context log: could not read #{key}: #{inspect(reason)}")
        :error
    end
  end

  defp fast_forward(state) do
    Enum.reduce(known_topics(state), state, fn topic, acc ->
      Enum.reduce(origins(acc, topic), acc, fn origin, acc2 ->
        case Store.list(acc2.store, origin_prefix(topic, origin)) do
          {:ok, []} -> acc2
          {:ok, keys} -> put_in(acc2.cursors[{topic, origin}], List.last(Enum.sort(keys)))
          {:error, _} -> acc2
        end
      end)
    end)
  end

  # ===========================================================================
  # Keys
  # ===========================================================================

  @doc """
  The object key for a delta.

      iex> delta = Jido.Context.Delta.new("knowledge.papers", "scout", 7, [])
      iex> Jido.Context.Mesh.Log.delta_key(delta)
      "topics/knowledge.papers/scout/00000000000000000007.json"
  """
  @spec delta_key(Delta.t()) :: String.t()
  def delta_key(%Delta{} = delta) do
    origin_prefix(delta.topic, delta.origin) <> pad(delta.seq) <> ".json"
  end

  @doc false
  @spec member_key(String.t(), String.t()) :: String.t()
  def member_key(topic, origin), do: member_prefix(topic) <> origin

  @doc false
  @spec member_prefix(String.t()) :: String.t()
  def member_prefix(topic), do: "members/" <> topic <> "/"

  @doc false
  @spec origin_prefix(String.t(), String.t()) :: String.t()
  def origin_prefix(topic, origin), do: "topics/" <> topic <> "/" <> origin <> "/"

  defp pad(seq), do: seq |> Integer.to_string() |> String.pad_leading(@seq_width, "0")

  defp topic_from_member_key(key) do
    case String.split(key, "/") do
      ["members", topic, _origin] -> topic
      _ -> nil
    end
  end
end
