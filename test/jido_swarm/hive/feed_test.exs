defmodule JidoSwarm.Hive.FeedTest do
  use ExUnit.Case, async: false

  alias Jido.Context
  alias JidoSwarm.Hive.Feed

  # Two replicas on one private mesh, as two pods would be — except that
  # without a transport the router alone carries deltas between them, which is
  # all the feed can see anyway.
  setup do
    n = System.unique_integer([:positive])
    mesh = :"feed_mesh_#{n}"
    start_supervised!({Context.Mesh, name: mesh, transports: []}, id: mesh)

    a = start_graph(:"feed_a_#{n}", "pod-a", mesh)
    b = start_graph(:"feed_b_#{n}", "pod-b", mesh)

    topic = "hive_test_#{n}"
    feed = :"feed_#{n}"
    start_supervised!({Feed, name: feed, graph: a, mesh: mesh, pubsub_topic: topic, ring: 5})
    Phoenix.PubSub.subscribe(JidoSwarm.PubSub, topic)

    {:ok, a: a, b: b, feed: feed, mesh: mesh}
  end

  defp start_graph(name, origin, mesh) do
    start_supervised!(
      {Context.Graph, name: name, origin: origin, mesh: mesh, location: :memory},
      id: name
    )

    name
  end

  test "knows which replica it is", %{feed: feed} do
    assert %{origin: "pod-a", node: node} = Feed.me(feed)
    assert node == node()
  end

  test "a remote write is announced, summarised, and marked as from elsewhere", %{b: b} do
    {:ok, _} =
      Context.commit(
        b,
        [
          {:put_node, "insight:i_1", ["HiveInsight"], %{"text" => "the parser is slow"}},
          {:put_edge, "insight:i_1", "ABOUT", "task:t_1", %{}}
        ],
        topic: "hive.memory"
      )

    assert_receive {:hive_delta, entry}
    assert entry.origin == "pod-b"
    refute entry.local
    assert entry.topic == "hive.memory"
    assert entry.ops == 2
    assert entry.kinds == ["insight"]
    assert entry.summary == ~s(+insight "the parser is slow" → ABOUT task:t_1)
    assert is_integer(entry.lag_ms) and entry.lag_ms >= 0
  end

  test "a local write is announced as local, without lag", %{a: a} do
    {:ok, _} =
      Context.assert(a, "agent:w1", ["HiveAgent"], %{"name" => "w1"}, topic: "hive.agents")

    assert_receive {:hive_delta, %{origin: "pod-a", local: true, lag_ms: nil, summary: summary}}
    assert summary == ~s(~agent "w1")
  end

  test "counts what each origin has written and how far behind it arrives", %{
    a: a,
    b: b,
    feed: feed
  } do
    {:ok, _} =
      Context.assert(a, "goal:g_1", ["HiveGoal"], %{"title" => "ship"}, topic: "hive.board")

    {:ok, _} =
      Context.commit(
        b,
        [
          {:put_node, "task:t_1", ["HiveTask"], %{"title" => "write it"}},
          {:put_edge, "task:t_1", "IN_GOAL", "goal:g_1", %{}}
        ],
        topic: "hive.board"
      )

    {:ok, _} =
      Context.assert(b, "task:t_2", ["HiveTask"], %{"title" => "test it"}, topic: "hive.board")

    assert_receive {:hive_delta, %{origin: "pod-b", seq: seq_b2, summary: ~s(+task "test it")}}

    [mine, theirs] = Feed.origins(feed)

    assert %{origin: "pod-a", local?: true, deltas: 1, nodes: 1, edges: 0, lag_p50_ms: nil} = mine
    assert %{origin: "pod-b", local?: false, deltas: 2, ops: 3, nodes: 2, edges: 1} = theirs
    assert theirs.last_seq == seq_b2
    assert is_integer(theirs.lag_p50_ms) and is_integer(theirs.lag_max_ms)
    assert theirs.age_ms >= 0

    assert %{origin: "pod-a", seen: %{"pod-a" => _, "pod-b" => ^seq_b2}} = Feed.identity(feed)
  end

  test "the ring keeps the newest deltas, newest first", %{b: b, feed: feed} do
    for i <- 1..8 do
      {:ok, _} =
        Context.assert(b, "note:n_#{i}", ["HiveNote"], %{"text" => "n#{i}"}, topic: "hive.memory")

      assert_receive {:hive_delta, _}
    end

    recent = Feed.recent(feed, 10)
    assert length(recent) == 5
    assert Enum.map(recent, & &1.summary) == for(i <- 8..4//-1, do: ~s(+note "n#{i}"))
    assert Feed.recent(feed, 2) == Enum.take(recent, 2)
  end

  test "the peer table starts with this replica", %{feed: feed} do
    assert [%{origin: "pod-a", local?: true, connected?: true, seen: %{}} | _] = Feed.peers(feed)
  end

  test "reset forgets everything", %{b: b, feed: feed} do
    {:ok, _} = Context.assert(b, "note:n_1", ["HiveNote"], %{"text" => "n"}, topic: "hive.memory")
    assert_receive {:hive_delta, _}

    :ok = Feed.reset(feed)
    assert Feed.recent(feed) == []
    assert Feed.origins(feed) == []
  end

  test "a burst is announced once per window, not once per delta", %{mesh: mesh} do
    # Sixty deltas inside a hundred milliseconds, as a log replay delivers
    # them: the first fifty are announced one by one, then the window fills
    # and the rest are one message.
    for i <- 1..60 do
      ops = [{:put_node, "burst:#{i}", ["HiveNote"], %{"text" => "b"}}]
      :ok = Context.Mesh.publish(mesh, Context.Delta.new("hive.memory", "pod-c", i, ops))
    end

    deltas = collect({:hive_delta, :_}, 2_000)
    bursts = collect({:hive_burst, :_}, 200)

    assert length(deltas) == 50
    assert length(bursts) == 1
  end

  defp collect(shape, timeout) do
    {tag, _} = shape

    receive do
      {^tag, payload} -> [{tag, payload} | collect(shape, timeout)]
    after
      timeout -> []
    end
  end
end
