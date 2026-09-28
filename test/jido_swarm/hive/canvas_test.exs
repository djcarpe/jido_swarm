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
