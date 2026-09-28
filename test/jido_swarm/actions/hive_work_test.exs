defmodule JidoSwarm.Actions.HiveWorkTest do
  use ExUnit.Case, async: true

  alias JidoSwarm.Actions.HiveWork

  # The configured repositories are jido, glider and glider_ex.
  test "a standing survey task names its repository in its key" do
    assert Enum.map(HiveWork.repos_for("task:standing:glider:3", ""), & &1.name) == ["glider"]
  end

  test "a repository mentioned in the pack, by name or as repo:<name>, is in hand" do
    names = fn context ->
      HiveWork.repos_for("task:t_1", context) |> Enum.map(& &1.name) |> Enum.sort()
    end

    assert names.("Look at the NIF boundary in glider_ex") == ["glider_ex"]
    assert names.("insight about repo:jido and its agents") == ["jido"]
    assert names.("compare jido with glider") == ["glider", "jido"]
  end

  test "a bare word inside another word is not a repository" do
    assert HiveWork.repos_for("task:t_1", "the gliders are unused") == []
    assert HiveWork.repos_for("task:t_1", "nothing about code here") == []
  end
end
