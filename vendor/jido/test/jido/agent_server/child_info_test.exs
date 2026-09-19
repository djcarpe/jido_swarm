defmodule JidoTest.AgentServer.ChildInfoTest do
  use ExUnit.Case, async: true

  alias Jido.AgentServer.ChildInfo

  describe "new/1" do
    test "creates a ChildInfo with valid attrs" do
      attrs = valid_attrs()
      assert {:ok, %ChildInfo{} = child_info} = ChildInfo.new(attrs)
      assert child_info.module == MyChildAgent
      assert child_info.id == "child-456"
      assert child_info.meta == %{}
      assert child_info.tag == nil
    end

    test "creates a ChildInfo with optional tag" do
      attrs = Map.put(valid_attrs(), :tag, :worker)
      assert {:ok, %ChildInfo{tag: :worker}} = ChildInfo.new(attrs)
    end

    test "creates a ChildInfo with custom meta" do
      attrs = Map.put(valid_attrs(), :meta, %{role: :processor})
      assert {:ok, %ChildInfo{meta: %{role: :processor}}} = ChildInfo.new(attrs)
    end

    test "returns error for non-map input" do
      assert {:error, error} = ChildInfo.new("not a map")
      assert error.message == "ChildInfo requires a map"
    end

    test "returns error for nil input" do
      assert {:error, error} = ChildInfo.new(nil)
      assert error.message == "ChildInfo requires a map"
    end

    test "returns error for list input" do
      assert {:error, error} = ChildInfo.new([])
      assert error.message == "ChildInfo requires a map"
    end

    test "returns error for missing required fields" do
      assert {:error, _reason} = ChildInfo.new(%{})
    end

    test "returns error when missing module" do
      attrs = Map.delete(valid_attrs(), :module)
      assert {:error, _reason} = ChildInfo.new(attrs)
    end
  end

  describe "new!/1" do
    test "returns ChildInfo on success" do
      child_info = ChildInfo.new!(valid_attrs())
      assert %ChildInfo{} = child_info
      assert child_info.id == "child-456"
      assert child_info.module == MyChildAgent
    end

    test "returns ChildInfo with all fields" do
      attrs = valid_attrs() |> Map.put(:tag, :processor) |> Map.put(:meta, %{priority: 1})
      child_info = ChildInfo.new!(attrs)
      assert child_info.tag == :processor
      assert child_info.meta == %{priority: 1}
    end

    test "raises on invalid attrs" do
      assert_raise Jido.Error.ValidationError, fn ->
        ChildInfo.new!(%{})
      end
    end

    test "raises on non-map input" do
      assert_raise Jido.Error.ValidationError, fn ->
        ChildInfo.new!("not a map")
      end
    end

    test "raises on nil input" do
      assert_raise Jido.Error.ValidationError, fn ->
        ChildInfo.new!(nil)
      end
    end
  end

  describe "schema/0" do
    test "returns the Zoi schema" do
      schema = ChildInfo.schema()
      assert is_struct(schema)
    end
  end

  defp valid_attrs do
    %{
      pid: self(),
      ref: make_ref(),
      module: MyChildAgent,
      id: "child-456"
    }
  end
end
