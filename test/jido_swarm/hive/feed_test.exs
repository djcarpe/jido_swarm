defmodule JidoSwarm.Hive.FeedTest do
  use ExUnit.Case, async: false

  alias Jido.Context
  alias JidoSwarm.Hive.Feed

  doctest Feed

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

    start_supervised!({Feed, name: feed, graph: a, mesh: mesh, pubsub_topic: topic, ring: 5},
      id: feed
    )

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

  describe "the probe" do
    setup %{b: b, mesh: mesh} do
      # The other replica's feed, so it can answer.
      n = System.unique_integer([:positive])
      other = :"feed_other_#{n}"

      start_supervised!(
        {Feed, name: other, graph: b, mesh: mesh, pubsub_topic: "hive_other_#{n}"}
      )

      {:ok, other: other}
    end

    test "a probe from one replica is answered by the other, through the graph", %{
      feed: feed,
      a: a,
      b: b
    } do
      {:ok, id} = Feed.probe(feed)

      # The probe node went out from pod-a and arrived on pod-b's graph...
      assert_receive {:hive_delta, %{origin: "pod-a", summary: "+probe" <> _}}
      assert {:ok, %{props: %{"origin" => "pod-a"}}} = Context.fetch(b, "probe:" <> id)

      # ...and pod-b's answer came back the same way, timed on arrival.
      assert_receive {:hive_probe, %{id: ^id, acks: [ack]}}, 2_000
      assert %{origin: "pod-b", rtt_ms: rtt, one_way_ms: one_way} = ack
      assert is_integer(rtt) and rtt >= 0 and is_integer(one_way)
      assert {:ok, %{props: %{"probe" => ^id}}} = Context.fetch(a, "ack:#{id}:pod-b")

      [probe] = Feed.probes(feed)
      assert probe.id == id and length(probe.acks) == 1
      refute probe.timed_out
    end

    test "a replica does not answer its own probe", %{feed: feed} do
      {:ok, id} = Feed.probe(feed)
      assert_receive {:hive_probe, %{id: ^id}}, 2_000
      refute_receive {:hive_probe, %{id: ^id, acks: [_, _]}}, 200
      [probe] = Feed.probes(feed)
      refute Enum.any?(probe.acks, &(&1.origin == "pod-a"))
    end
  end

  describe "the conflict demo" do
    test "needs another pod", %{feed: feed} do
      assert Feed.conflict(feed) == {:error, :no_peers}
    end

    test "two writes to one key converge on the higher stamp everywhere", %{
      a: a,
      b: b,
      feed: feed,
      mesh: mesh
    } do
      n = System.unique_integer([:positive])
      other = :"feed_other_#{n}"

      start_supervised!(
        {Feed, name: other, graph: b, mesh: mesh, pubsub_topic: "hive_other_#{n}"}
      )

      {:ok, mine} = Feed.write_conflict(feed, "demo:conflict")
      {:ok, theirs} = Feed.write_conflict(other, "demo:conflict")
      :ok = Context.sync(a)
      :ok = Context.sync(b)

      assert mine.origin == "pod-a" and theirs.origin == "pod-b"

      {:ok, %{props: on_a}} = Context.fetch(a, "demo:conflict")
      {:ok, %{props: on_b}} = Context.fetch(b, "demo:conflict")
      assert {on_a["_seq"], on_a["_origin"]} == {on_b["_seq"], on_b["_origin"]}

      winner = {on_a["_seq"], on_a["_origin"]}
      stamps = [{mine.seq, mine.origin}, {theirs.seq, theirs.origin}]
      assert winner == Enum.max_by(stamps, fn {seq, origin} -> {seq, origin} end)
      assert Feed.explain(winner, Enum.min(stamps)) =~ "wins"
    end
  end

  describe "what the rule decided" do
    test "a write that loses to a higher stamp is announced as lost", %{
      a: a,
      feed: feed,
      mesh: mesh
    } do
      {:ok, kept} =
        Context.assert(a, "task:t_1", ["HiveTask"], %{"title" => "kept"}, topic: "hive.board")

      assert_receive {:hive_delta, %{local: true}}

      # A stale write from another pod: it arrives, the ticker shows it, and
      # then the graph reports it lost.
      stale =
        Context.Delta.new("hive.board", "pod-b", 0, [
          {:put_node, "task:t_1", ["HiveTask"], %{"title" => "stale"}},
          {:put_edge, "task:t_1", "IN_GOAL", "goal:g_1", %{}}
        ])

      :ok = Context.Mesh.publish(mesh, stale)
      stale_id = stale.id
      assert_receive {:hive_delta, %{id: ^stale_id, origin: "pod-b", outcome: nil}}

      assert_receive {:hive_outcome,
                      %{id: ^stale_id, origin: "pod-b", superseded: ["task:t_1"], tombstoned: []}},
                     2_000

      assert {:ok, %{props: %{"title" => "kept", "_seq" => seq}}} = Context.fetch(a, "task:t_1")
      assert seq == kept.seq

      [entry | _] = Feed.recent(feed, 5)
      assert entry.id == stale_id and entry.outcome == %{superseded: 1, applied: 1}

      theirs = Enum.find(Feed.origins(feed), &(&1.origin == "pod-b"))
      assert theirs.superseded == 1 and theirs.tombstoned == 0
    end

    test "a duplicate delivery is counted against its origin", %{feed: feed, mesh: mesh} do
      delta =
        Context.Delta.new("hive.board", "pod-b", 1, [
          {:put_node, "note:n_1", ["HiveNote"], %{"text" => "x"}}
        ])

      :ok = Context.Mesh.publish(mesh, delta)
      :ok = Context.Mesh.deliver(mesh, delta)
      :ok = Context.Mesh.sync(mesh)
      assert_receive {:hive_delta, _}

      assert Enum.find(Feed.origins(feed), &(&1.origin == "pod-b")).duplicates == 1
    end
  end

  test "reset forgets everything", %{b: b, feed: feed} do
    {:ok, _} = Context.assert(b, "note:n_1", ["HiveNote"], %{"text" => "n"}, topic: "hive.memory")
    assert_receive {:hive_delta, _}

    :ok = Feed.reset(feed)
    assert Feed.recent(feed, 10) == []
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
