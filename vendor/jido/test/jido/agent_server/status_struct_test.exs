defmodule JidoTest.AgentServer.StatusStructTest.FakeSnapshot do
  defstruct status: :idle, done?: false, result: nil, details: %{}
end

defmodule JidoTest.AgentServer.StatusStructTest do
  use ExUnit.Case, async: true

  alias Jido.AgentServer.Status
  alias JidoTest.AgentServer.StatusStructTest.FakeSnapshot

  describe "new/1" do
    test "creates a Status with valid attrs" do
      attrs = valid_attrs()
      assert {:ok, %Status{} = status} = Status.new(attrs)
      assert status.agent_module == MyAgent
      assert status.agent_id == "agent-123"
      assert status.raw_state == %{internal: "data"}
    end

    test "returns error for non-map input" do
      assert {:error, error} = Status.new("not a map")
      assert error.message == "Status requires a map"
    end

    test "returns error for nil input" do
      assert {:error, error} = Status.new(nil)
      assert error.message == "Status requires a map"
    end

    test "returns error for list input" do
      assert {:error, error} = Status.new([])
      assert error.message == "Status requires a map"
    end

    test "returns error for missing required fields" do
      assert {:error, _reason} = Status.new(%{})
    end
  end

  describe "status/1" do
    test "returns the snapshot's status" do
      {:ok, status} = Status.new(valid_attrs())
      assert Status.status(status) == :running
    end

    test "returns idle status" do
      attrs = put_in(valid_attrs(), [:snapshot], %FakeSnapshot{status: :idle})
      {:ok, status} = Status.new(attrs)
      assert Status.status(status) == :idle
    end

    test "returns success status" do
      attrs = put_in(valid_attrs(), [:snapshot], %FakeSnapshot{status: :success, done?: true})
      {:ok, status} = Status.new(attrs)
      assert Status.status(status) == :success
    end
  end

  describe "done?/1" do
    test "returns false when not done" do
      {:ok, status} = Status.new(valid_attrs())
      assert Status.done?(status) == false
    end

    test "returns true when done" do
      attrs =
        put_in(valid_attrs(), [:snapshot], %FakeSnapshot{
          status: :success,
          done?: true,
          result: :ok
        })

      {:ok, status} = Status.new(attrs)
      assert Status.done?(status) == true
    end
  end

  describe "result/1" do
    test "returns nil when no result" do
      {:ok, status} = Status.new(valid_attrs())
      assert Status.result(status) == nil
    end

    test "returns the result value" do
      attrs =
        put_in(valid_attrs(), [:snapshot], %FakeSnapshot{
          status: :success,
          done?: true,
          result: {:ok, "completed"}
        })

      {:ok, status} = Status.new(attrs)
      assert Status.result(status) == {:ok, "completed"}
    end
  end

  describe "details/1" do
    test "returns empty map when no details" do
      attrs = put_in(valid_attrs(), [:snapshot], %FakeSnapshot{details: %{}})
      {:ok, status} = Status.new(attrs)
      assert Status.details(status) == %{}
    end

    test "returns the details map" do
      {:ok, status} = Status.new(valid_attrs())
      assert Status.details(status) == %{step: 1}
    end

    test "returns complex details" do
      details = %{step: 3, iterations: 10, last_action: :process}
      attrs = put_in(valid_attrs(), [:snapshot], %FakeSnapshot{details: details})
      {:ok, status} = Status.new(attrs)
      assert Status.details(status) == details
    end
  end

  describe "schema/0" do
    test "returns the Zoi schema" do
      schema = Status.schema()
      assert is_struct(schema)
    end
  end

  defp valid_attrs do
    %{
      agent_module: MyAgent,
      agent_id: "agent-123",
      pid: self(),
      snapshot: %FakeSnapshot{status: :running, done?: false, result: nil, details: %{step: 1}},
      raw_state: %{internal: "data"}
    }
  end
end
