defmodule JidoTest.Case do
  @moduledoc """
  Test case module that provides isolated Jido instances for testing.

  ## Usage

      defmodule MyTest do
        use JidoTest.Case, async: true
        
        test "my test", %{jido: jido} do
          {:ok, pid} = Jido.start_agent(jido, MyAgent)
          # ...
        end
      end

  Each test gets a unique Jido instance that is automatically started before
  the test and stopped after it completes. This ensures complete test isolation.

  ## Context

  The following keys are available in the test context:

  - `:jido` - The name of the Jido instance (atom)
  - `:jido_pid` - The PID of the Jido supervisor

  ## Helper Functions

  The module also provides helper functions:

  - `start_test_agent/2` - Starts an agent under the test's Jido instance
  - `test_registry/1` - Returns the registry name for the test's Jido instance
  - `unique_id/1` - Generates a unique ID with optional prefix
  - `signal/3` - Creates a test signal with sensible defaults
  - `start_server/3` - Starts an agent server with automatic cleanup
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import JidoTest.Case
      import JidoTest.Eventually

      @doc """
      Starts an agent under this test's Jido instance.
      """
      def start_test_agent(context, agent, opts \\ []) do
        Jido.start_agent(context.jido, agent, opts)
      end

      @doc """
      Returns the registry for this test's Jido instance.
      """
      def test_registry(context) do
        Jido.registry_name(context.jido)
      end

      @doc """
      Returns the task supervisor for this test's Jido instance.
      """
      def test_task_supervisor(context) do
        Jido.task_supervisor_name(context.jido)
      end

      @doc """
      Returns the agent supervisor for this test's Jido instance.
      """
      def test_agent_supervisor(context) do
        Jido.agent_supervisor_name(context.jido)
      end
    end
  end

  @doc """
  Generates a unique ID with an optional prefix.

  ## Examples

      unique_id()        # "test-12345"
      unique_id("agent") # "agent-12346"
  """
  def unique_id(prefix \\ "test") do
    "#{prefix}-#{System.unique_integer([:positive])}"
  end

  @doc """
  Creates a test signal with sensible defaults.

  ## Examples

      signal("increment")
      signal("record", %{message: "hello"})
      signal("test", %{}, source: "/custom")
  """
  def signal(type, data \\ %{}, opts \\ []) do
    source = Keyword.get(opts, :source, "/test")
    Jido.Signal.new!(type, data, source: source)
  end

  @doc """
  Starts an agent server with automatic cleanup on test exit.

  ## Options

  All options are passed to `Jido.AgentServer.start_link/1`, with defaults:

    * `:jido` - Uses the test context's jido instance
    * `:id` - Generates a unique ID if not provided

  ## Examples

      pid = start_server(context, MyAgent)
      pid = start_server(context, MyAgent, id: "custom-id")
  """
  def start_server(context, agent, opts \\ []) do
    opts = Keyword.put_new(opts, :jido, context.jido)
    opts = Keyword.put_new(opts, :id, unique_id())
    {:ok, pid} = Jido.AgentServer.start_link([agent: agent] ++ opts)

    ExUnit.Callbacks.on_exit(fn ->
      if Process.alive?(pid) do
        try do
          GenServer.stop(pid, :normal, 100)
        catch
          :exit, _ -> :ok
        end
      end
    end)

    pid
  end

  setup context do
    test_id = System.unique_integer([:positive])
    jido_name = :"jido_test_#{test_id}"

    {:ok, jido_pid} = Jido.start_link(name: jido_name)

    {:ok, Map.merge(context, %{jido: jido_name, jido_pid: jido_pid})}
  end
end
