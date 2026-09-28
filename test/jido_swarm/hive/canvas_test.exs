defmodule JidoSwarm.Hive.CanvasTest do
  use ExUnit.Case, async: false

  alias Jido.Context
  alias Jido.Context.Delta
  alias JidoSwarm.Hive.Canvas

  doctest Canvas

  # A private graph the Hive's store reads, with writes stamped by two origins:
  # this replica writes through the graph, the other arrives as a delta.
  setup do
    name = :"canvas_#{System.unique_integer([:positive])}"
    start_supervised!({Context.Graph, name: name, origin: "pod-a", location: :memory})
    Application.put_env(:jido_swarm, :hive_graph, name)
    on_exit(fn -> Application.delete_env(:jido_swarm, :hive_graph) end)
    {:ok, graph: name}
  end

  defp from_elsewhere(graph, origin, seq, ops) do
    :ok = Context.Graph.apply_delta(graph, Delta.new("hive.board", origin, seq, ops))
    :ok = Context.sync(graph)
  end

  describe "summarize/1" do
    test "puts, upserts, drops and edges each read as a verb" do
      delta =
        Delta.new("hive.memory", "pod-a", 1, [
          {:put_node, "insight:i_1", ["HiveInsight"], %{"text" => "the parser is slow"}},
          {:put_node, "claim:t_1", ["HiveClaim"], %{"state" => "claimed"}},
          {:put_edge, "insight:i_1", "ABOUT", "task:t_1", %{}},
          {:drop_node, "note:n_9"},
          {:drop_edge, "a", "ON", "b"}
        ])

      assert Canvas.summarize(delta) ==
               ~s(+insight "the parser is slow" ~claim → ABOUT task:t_1 +2 more)
    end

    test "a long text is cut to one line" do
      text = String.duplicate("word ", 20)

      delta =
        Delta.new("hive.memory", "pod-a", 1, [
          {:put_node, "note:n_1", ["HiveNote"], %{"text" => text}}
        ])

      assert Canvas.summarize(delta) == ~s(+note "word word word word word word word word…")
    end

    test "a placeholder is named by its key" do
      delta = Delta.new("hive.board", "pod-a", 1, [{:put_node, "task:t_1", [], %{}}])
      assert Canvas.summarize(delta) == "+task"
    end
  end

  describe "snapshot/1" do
    test "draws the newest entities, the edges between them, and says what was left out", %{
      graph: graph
    } do
      {:ok, _} = Context.assert(graph, "goal:g_1", ["HiveGoal"], %{"title" => "ship"})

      from_elsewhere(graph, "pod-b", 1, [
        {:put_node, "task:t_1", ["HiveTask"], %{"title" => "write it"}},
        {:put_edge, "task:t_1", "IN_GOAL", "goal:g_1", %{}},
        {:put_edge, "task:t_1", "DEPENDS_ON", "task:t_0", %{}}
      ])

      snapshot = Canvas.snapshot()

      assert snapshot.total == 3
      refute snapshot.truncated
      by_key = Map.new(snapshot.nodes, &{&1.key, &1})

      assert %{kind: "goal", caption: "ship", origin: "pod-a", ghost: false} = by_key["goal:g_1"]
      assert %{kind: "task", caption: "write it", origin: "pod-b", seq: 1} = by_key["task:t_1"]
      # The dependency's end never arrived: the graph made a placeholder.
      assert %{kind: "task", ghost: true, labels: []} = by_key["task:t_0"]

      assert Enum.map(snapshot.edges, & &1.id) |> Enum.sort() ==
               ["task:t_1|DEPENDS_ON|task:t_0", "task:t_1|IN_GOAL|goal:g_1"]

      assert Enum.all?(snapshot.edges, &(&1.origin == "pod-b"))

      # With room for two, the newest two are sent and the rest is counted.
      small = Canvas.snapshot(cap: 2)
      assert length(small.nodes) == 2
      assert small.truncated and small.total == 3
      kept = MapSet.new(small.nodes, & &1.key)

      assert Enum.all?(
               small.edges,
               &(MapSet.member?(kept, &1.from) and MapSet.member?(kept, &1.to))
             )
    end

    test "carries the heat on a task", %{graph: graph} do
      {:ok, _} = Context.assert(graph, "task:t_1", ["HiveTask"], %{"title" => "hot"})
      :ok = JidoSwarm.Hive.Memory.touch("agent:w1", "task:t_1")

      [task] = Canvas.snapshot().nodes |> Enum.filter(&(&1.key == "task:t_1"))
      assert task.heat > 0.9
    end
  end

  describe "delta_ops/1" do
    test "turns every operation into something to draw" do
      delta =
        Delta.new(
          "hive.memory",
          "pod-b",
          7,
          [
            {:put_node, "insight:i_1", ["HiveInsight"], %{"text" => "slow"}},
            {:put_edge, "insight:i_1", "ABOUT", "task:t_1", %{}},
            {:drop_node, "note:n_1"},
            {:drop_edge, "a", "ON", "b"}
          ],
          ts: 1_000
        )

      assert [
               %{
                 op: "put_node",
                 node: %{
                   key: "insight:i_1",
                   kind: "insight",
                   caption: "slow",
                   origin: "pod-b",
                   seq: 7,
                   ts: 1_000,
                   topic: "hive.memory",
                   ghost: false
                 }
               },
               %{
                 op: "put_edge",
                 edge: %{
                   id: "insight:i_1|ABOUT|task:t_1",
                   from: "insight:i_1",
                   to: "task:t_1",
                   type: "ABOUT",
                   origin: "pod-b",
                   seq: 7
                 }
               },
               %{op: "drop_node", key: "note:n_1"},
               %{op: "drop_edge", id: "a|ON|b"}
             ] = Canvas.delta_ops(delta)
    end
  end

  describe "detail/1, neighbours/1 and nodes/1" do
    setup %{graph: graph} do
      {:ok, _} =
        Context.assert(graph, "goal:g_1", ["HiveGoal"], %{"title" => "ship", "priority" => 3})

      from_elsewhere(graph, "pod-b", 1, [
        {:put_node, "task:t_1", ["HiveTask"], %{"title" => "write it"}},
        {:put_edge, "task:t_1", "IN_GOAL", "goal:g_1", %{}},
        {:put_node, "insight:i_1", ["HiveInsight"], %{"text" => "hard"}},
        {:put_edge, "insight:i_1", "ABOUT", "task:t_1", %{}}
      ])

      :ok
    end

    test "detail is the entity, its own properties, its stamp and its neighbours" do
      detail = Canvas.detail("task:t_1")

      assert detail.node.caption == "write it"
      assert detail.props == %{"title" => "write it"}
      assert %{origin: "pod-b", seq: 1, topic: "hive.board", age_ms: age} = detail.stamp
      assert age >= 0

      assert Enum.sort_by(detail.neighbours, & &1.key) == [
               %{
                 key: "goal:g_1",
                 type: "IN_GOAL",
                 dir: "out",
                 kind: "goal",
                 caption: "ship",
                 origin: "pod-a"
               },
               %{
                 key: "insight:i_1",
                 type: "ABOUT",
                 dir: "in",
                 kind: "insight",
                 caption: "hard",
                 origin: "pod-b"
               }
             ]

      assert Canvas.detail("task:nope") == nil
    end

    test "neighbours are what to add around a node" do
      %{nodes: nodes, edges: edges} = Canvas.neighbours("task:t_1")

      assert Enum.map(nodes, & &1.key) |> Enum.sort() == ["goal:g_1", "insight:i_1"]

      assert Enum.map(edges, & &1.id) |> Enum.sort() == [
               "insight:i_1|ABOUT|task:t_1",
               "task:t_1|IN_GOAL|goal:g_1"
             ]
    end

    test "nodes re-reads keys, skipping ones that are gone" do
      assert [%{key: "goal:g_1", origin: "pod-a"}, %{key: "task:t_1", origin: "pod-b"}] =
               Canvas.nodes(["goal:g_1", "task:t_1", "task:gone"]) |> Enum.sort_by(& &1.key)

      assert Canvas.nodes([]) == []
    end
  end

  describe "authorship/1" do
    test "counts nodes and edges by the origin that wrote them", %{graph: graph} do
      {:ok, _} = Context.assert(graph, "goal:g_1", ["HiveGoal"], %{"title" => "ship"})

      from_elsewhere(graph, "pod-b", 1, [
        {:put_node, "task:t_1", ["HiveTask"], %{"title" => "write"}},
        {:put_node, "task:t_2", ["HiveTask"], %{"title" => "test"}},
        {:put_edge, "task:t_1", "IN_GOAL", "goal:g_1", %{}}
      ])

      authorship = Canvas.authorship("pod-a")

      assert authorship.nodes == %{"pod-a" => 1, "pod-b" => 2}
      assert authorship.edges == %{"pod-b" => 1}
      assert authorship.total_nodes == 3
      assert authorship.total_edges == 1
      assert_in_delta authorship.remote_share, 2 / 3, 0.001
    end

    test "an empty graph has no share to report" do
      assert %{total_nodes: 0, remote_share: nil} = Canvas.authorship("pod-a")
    end
  end

  describe "origin_colors/2" do
    test "this replica is always the first colour, the rest follow by name" do
      colors = Canvas.origin_colors(["pod-c", "pod-b", "pod-a"], "pod-b")

      assert map_size(colors) == 3
      assert colors["pod-b"] == Canvas.origin_colors([], "pod-b")["pod-b"]
      assert colors["pod-a"] != colors["pod-b"]
      assert colors["pod-c"] != colors["pod-a"]
      # Order of discovery does not change anyone's colour.
      assert Canvas.origin_colors(["pod-a", "pod-c"], "pod-b") == colors
    end
  end
end
