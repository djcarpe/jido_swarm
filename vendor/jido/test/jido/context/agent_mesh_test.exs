defmodule Jido.Context.AgentMeshTest do
  @moduledoc """
  Three real Jido agents sharing one context and knowledge mesh.

  Everything below goes through the agent runtime — signals in, actions run,
  graph written — rather than calling `Jido.Context` directly, because the
  thing being tested is that an ordinary agent gains a shared graph by mounting
  a plugin.
  """

  use JidoTest.Case, async: false

  import JidoTest.Eventually

  alias Jido.Context
  alias Jido.Context.Graph
  alias Jido.Context.Mesh

  @graphs [:scout_graph, :librarian_graph, :analyst_graph]

  defmodule Scout do
    @moduledoc false
    use Jido.Agent,
      name: "mesh_scout",
      description: "Finds things and puts them on the mesh",
      plugins: [
        {Jido.Context.Plugin,
         %{graph: :scout_graph, mesh: :agent_mesh_test, topics: ["knowledge.**"]}}
      ]
  end

  defmodule Librarian do
    @moduledoc false
    use Jido.Agent,
      name: "mesh_librarian",
      description: "Organises what the scout found",
      plugins: [
        {Jido.Context.Plugin,
         %{graph: :librarian_graph, mesh: :agent_mesh_test, topics: ["knowledge.**"]}}
      ]
  end

  defmodule Analyst do
    @moduledoc false
    use Jido.Agent,
      name: "mesh_analyst",
      description: "Reads the whole mesh and reasons over it",
      plugins: [
        {Jido.Context.Plugin, %{graph: :analyst_graph, mesh: :agent_mesh_test, topics: ["**"]}}
      ]
  end

  setup context do
    # The graph names are fixed by each agent's plugin config, so a previous
    # test's graphs must have finished unregistering before the next test's
    # agents try to claim the same names.
    assert_eventually(Enum.all?(@graphs, &(Process.whereis(Graph.process_name(&1)) == nil)))

    start_supervised!({Mesh, name: :agent_mesh_test, transports: [:pg]})

    scout = start_server(context, Scout, id: "scout")
    librarian = start_server(context, Librarian, id: "librarian")
    analyst = start_server(context, Analyst, id: "analyst")

    {:ok, scout: scout, librarian: librarian, analyst: analyst}
  end

  defp settle do
    :ok = Mesh.sync(:agent_mesh_test)
    for g <- @graphs, do: Context.sync(g)
    :ok
  end

  test "each agent gets its own graph, started under the agent" do
    # Plugin children are started from the agent's `:post_init` continuation,
    # so they come up just after `start_link/1` returns rather than during it.
    for graph <- @graphs do
      assert_eventually(is_pid(Process.whereis(Graph.process_name(graph))))
    end
  end

  test "a fact asserted by one agent is readable by all three", %{scout: scout} do
    {:ok, _} =
      Jido.AgentServer.call(
        scout,
        signal("context.assert", %{
          key: "paper:attention",
          labels: ["Paper"],
          props: %{"title" => "Attention Is All You Need", "year" => 2017},
          topic: "knowledge.papers"
        })
      )

    settle()

    for graph <- @graphs do
      assert {:ok, %{rows: [["Attention Is All You Need", 2017]]}} =
               Context.query(graph, "MATCH (p:Paper) RETURN p.title, p.year"),
             "#{graph} did not see the scout's assertion"
    end
  end

  test "agents build one graph together, each contributing part of it",
       %{scout: scout, librarian: librarian} do
    {:ok, _} =
      Jido.AgentServer.call(
        scout,
        signal("context.assert", %{
          key: "paper:attention",
          labels: ["Paper"],
          props: %{"title" => "Attention"},
          topic: "knowledge.papers"
        })
      )

    {:ok, _} =
      Jido.AgentServer.call(
        scout,
        signal("context.assert", %{
          key: "paper:seq2seq",
          labels: ["Paper"],
          props: %{"title" => "Seq2Seq"},
          topic: "knowledge.papers"
        })
      )

    settle()

    # The librarian relates two papers the scout found — it can only do this
    # because the scout's nodes reached its graph.
    {:ok, _} =
      Jido.AgentServer.call(
        librarian,
        signal("context.relate", %{
          from: "paper:attention",
          type: "CITES",
          to: "paper:seq2seq",
          topic: "knowledge.papers"
        })
      )

    settle()

    # And the analyst, who wrote none of it, can traverse the result.
    assert {:ok, %{rows: [["Attention", "Seq2Seq"]]}} =
             Context.query(
               :analyst_graph,
               "MATCH (a:Paper)-[:CITES]->(b:Paper) RETURN a.title, b.title"
             )
  end

  test "an agent can query the mesh by signal and get rows back", %{
    scout: scout,
    analyst: analyst
  } do
    {:ok, _} =
      Jido.AgentServer.call(
        scout,
        signal("context.assert", %{
          key: "paper:1",
          labels: ["Paper"],
          props: %{"title" => "Queried"},
          topic: "knowledge.papers"
        })
      )

    settle()

    {:ok, agent} =
      Jido.AgentServer.call(
        analyst,
        signal("context.query", %{cypher: "MATCH (p:Paper) RETURN p.title"})
      )

    assert %{rows: [["Queried"]]} = agent.state
  end

  test "context scopes are shared too", %{librarian: librarian, analyst: analyst} do
    {:ok, _} =
      Jido.AgentServer.call(
        librarian,
        signal("context.remember", %{
          scope: "task:42",
          name: "assigned_to",
          value: "scout",
          topic: "knowledge.tasks"
        })
      )

    settle()

    {:ok, agent} =
      Jido.AgentServer.call(analyst, signal("context.recall", %{scope: "task:42"}))

    assert %{entries: %{"assigned_to" => "scout"}} = agent.state
  end

  test "a topic an agent did not subscribe to does not reach it", %{scout: scout} do
    # The scout and librarian take knowledge.**; the analyst takes **.
    {:ok, _} =
      Jido.AgentServer.call(
        scout,
        signal("context.assert", %{
          key: "gossip:1",
          labels: ["Gossip"],
          props: %{},
          topic: "chatter.idle"
        })
      )

    settle()

    assert {:ok, %{rows: [_]}} = Context.query(:analyst_graph, "MATCH (g:Gossip) RETURN g")
    assert {:ok, %{rows: []}} = Context.query(:librarian_graph, "MATCH (g:Gossip) RETURN g")
  end

  test "a retraction by one agent removes the fact everywhere", %{
    scout: scout,
    librarian: librarian
  } do
    {:ok, _} =
      Jido.AgentServer.call(
        scout,
        signal("context.assert", %{
          key: "paper:wrong",
          labels: ["Paper"],
          props: %{"title" => "Retracted"},
          topic: "knowledge.papers"
        })
      )

    settle()
    assert {:ok, %{rows: [_]}} = Context.query(:librarian_graph, "MATCH (p:Paper) RETURN p")

    {:ok, _} = Context.retract(:librarian_graph, "paper:wrong", topic: "knowledge.papers")
    settle()

    assert {:ok, %{rows: []}} = Context.query(:scout_graph, "MATCH (p:Paper) RETURN p")
    assert {:ok, %{rows: []}} = Context.query(:analyst_graph, "MATCH (p:Paper) RETURN p")
    assert is_pid(librarian)
  end

  test "stopping an agent releases its graph", %{scout: scout} do
    assert_eventually(is_pid(Process.whereis(Graph.process_name(:scout_graph))))

    graph_pid = Process.whereis(Graph.process_name(:scout_graph))
    ref = Process.monitor(graph_pid)

    :ok = GenServer.stop(scout)

    assert_receive {:DOWN, ^ref, :process, ^graph_pid, _}, 2_000
  end
end
