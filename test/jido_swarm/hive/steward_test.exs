defmodule JidoSwarm.Hive.StewardTest do
  use ExUnit.Case, async: false

  alias JidoSwarm.Hive
  alias JidoSwarm.Hive.Board
  alias JidoSwarm.Hive.Claims
  alias JidoSwarm.Hive.Steward

  setup do
    name = :"steward_#{System.unique_integer([:positive])}"
    start_supervised!({Jido.Context.Graph, name: name, location: :memory})
    Application.put_env(:jido_swarm, :hive_graph, name)
    Application.put_env(:jido_swarm, :hive_settle_ms, 0)

    on_exit(fn ->
      Application.delete_env(:jido_swarm, :hive_graph)
      Application.delete_env(:jido_swarm, :hive_settle_ms)
    end)

    repos = [
      %{name: "jido", url: "https://example/jido", test_command: "mix test"},
      %{name: "glider", url: "https://example/glider", test_command: "cargo test"}
    ]

    {:ok, repos: repos}
  end

  test "an empty board gets the standing goal and one task per repository", %{repos: repos} do
    assert {:ok, keys} = Steward.seed(repos: repos, title: "Learn")
    assert Enum.sort(keys) == ["task:standing:glider:1", "task:standing:jido:1"]

    [goal] = Hive.goals()
    assert goal.key == Steward.goal_key() and goal.title == "Learn" and goal.tasks == 2

    glider = Board.task("task:standing:glider:1")
    assert glider.goal == Steward.goal_key()
    assert glider.skills == ["research", "rust"]
    assert glider.detail =~ "insight about repo:glider"
    assert glider.status == "open"
  end

  test "seeding again adds nothing while every repository has live work", %{repos: repos} do
    {:ok, _} = Steward.seed(repos: repos)
    assert {:ok, []} = Steward.seed(repos: repos)

    # Claimed is still live.
    {:ok, agent} = Hive.join(name: "w", kind: "worker", skills: ["research", "rust"])
    {:ok, _} = Claims.claim("task:standing:glider:1", agent.id)
    assert {:ok, []} = Steward.seed(repos: repos)
    assert length(Hive.tasks()) == 2
  end

  test "a finished repository gets the next round", %{repos: repos} do
    {:ok, _} = Steward.seed(repos: repos)
    {:ok, agent} = Hive.join(name: "w", kind: "worker", skills: ["research", "rust"])
    {:ok, _} = Claims.claim("task:standing:glider:1", agent.id)
    :ok = Hive.finish(agent.id, "task:standing:glider:1", "learned things")

    assert {:ok, ["task:standing:glider:2"]} = Steward.seed(repos: repos)
    assert Board.task("task:standing:glider:2").title =~ "round 2"
    assert Board.task("task:standing:glider:1").status == "done"
  end

  test "two pods seeding converge on one goal", %{repos: repos} do
    {:ok, _} = Steward.seed(repos: repos)
    {:ok, _} = Board.add_goal(%{key: Steward.goal_key(), title: "again", created_by: "steward"})
    assert length(Hive.goals()) == 1
  end
end
