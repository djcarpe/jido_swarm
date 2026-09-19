defmodule JidoTest.AgentServer.ParentRefTest do
  use ExUnit.Case, async: true

  alias Jido.AgentServer.ParentRef

  @valid_attrs %{
    pid: self(),
    id: "parent-123",
    tag: :worker
  }

  describe "new/1" do
    test "creates a ParentRef with valid attrs" do
      assert {:ok, %ParentRef{} = parent_ref} = ParentRef.new(@valid_attrs)
      assert parent_ref.id == "parent-123"
      assert parent_ref.tag == :worker
      assert parent_ref.meta == %{}
    end

    test "creates a ParentRef with custom meta" do
      attrs = Map.put(@valid_attrs, :meta, %{priority: :high})
      assert {:ok, %ParentRef{meta: %{priority: :high}}} = ParentRef.new(attrs)
    end

    test "returns error for non-map input" do
      assert {:error, error} = ParentRef.new("not a map")
      assert error.message == "ParentRef requires a map"
    end

    test "returns error for nil input" do
      assert {:error, error} = ParentRef.new(nil)
      assert error.message == "ParentRef requires a map"
    end

    test "returns error for list input" do
      assert {:error, error} = ParentRef.new([])
      assert error.message == "ParentRef requires a map"
    end

    test "returns error for missing required fields" do
      assert {:error, _reason} = ParentRef.new(%{})
    end
  end

  describe "new!/1" do
    test "returns ParentRef on success" do
      parent_ref = ParentRef.new!(@valid_attrs)
      assert %ParentRef{} = parent_ref
      assert parent_ref.id == "parent-123"
    end

    test "raises on invalid attrs" do
      assert_raise Jido.Error.ValidationError, fn ->
        ParentRef.new!(%{})
      end
    end

    test "raises on non-map input" do
      assert_raise Jido.Error.ValidationError, fn ->
        ParentRef.new!("not a map")
      end
    end
  end

  describe "validate/1" do
    test "returns ok for valid ParentRef struct" do
      {:ok, parent_ref} = ParentRef.new(@valid_attrs)
      assert {:ok, ^parent_ref} = ParentRef.validate(parent_ref)
    end

    test "creates ParentRef from valid map" do
      assert {:ok, %ParentRef{id: "parent-123"}} = ParentRef.validate(@valid_attrs)
    end

    test "returns error for invalid map" do
      assert {:error, _reason} = ParentRef.validate(%{invalid: "data"})
    end

    test "returns error for non-map, non-struct input" do
      assert {:error, error} = ParentRef.validate("not valid")
      assert error.message == "Expected a ParentRef struct or map"
    end

    test "returns error for nil input" do
      assert {:error, error} = ParentRef.validate(nil)
      assert error.message == "Expected a ParentRef struct or map"
    end

    test "returns error for list input" do
      assert {:error, error} = ParentRef.validate([])
      assert error.message == "Expected a ParentRef struct or map"
    end

    test "returns error for integer input" do
      assert {:error, error} = ParentRef.validate(123)
      assert error.message == "Expected a ParentRef struct or map"
    end
  end

  describe "schema/0" do
    test "returns the Zoi schema" do
      schema = ParentRef.schema()
      assert is_struct(schema)
    end
  end
end
