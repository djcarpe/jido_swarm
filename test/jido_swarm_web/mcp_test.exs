defmodule JidoSwarmWeb.MCPTest do
  use JidoSwarmWeb.ConnCase, async: false

  alias JidoSwarm.Hive

  setup do
    name = :"mcp_#{System.unique_integer([:positive])}"
    start_supervised!({Jido.Context.Graph, name: name, location: :memory})
    Application.put_env(:jido_swarm, :hive_graph, name)
    Application.put_env(:jido_swarm, :hive_settle_ms, 0)

    on_exit(fn ->
      Application.delete_env(:jido_swarm, :hive_graph)
      Application.delete_env(:jido_swarm, :hive_settle_ms)
      Application.delete_env(:jido_swarm, :mcp_token)
    end)

    :ok
  end

  defp rpc(conn, method, params \\ %{}, session \\ nil) do
    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> then(&if(session, do: put_req_header(&1, "mcp-session-id", session), else: &1))
      |> post("/mcp", Jason.encode!(%{jsonrpc: "2.0", id: 1, method: method, params: params}))

    {conn, if(conn.status == 200, do: Jason.decode!(conn.resp_body), else: nil)}
  end

  defp session(conn) do
    {conn, resp} =
      rpc(conn, "initialize", %{
        protocolVersion: "2025-06-18",
        capabilities: %{},
        clientInfo: %{name: "test", version: "1"}
      })

    assert resp["result"]["protocolVersion"] == "2025-06-18"
    [sid] = get_resp_header(conn, "mcp-session-id")
    sid
  end

  defp call(sid, tool, args) do
    {_, resp} = rpc(build_conn(), "tools/call", %{name: tool, arguments: args}, sid)
    result = resp["result"]
    {result["isError"], result["structuredContent"], hd(result["content"])["text"]}
  end

  test "initialize, list tools, and an unknown method", %{conn: conn} do
    sid = session(conn)
    {_, resp} = rpc(build_conn(), "tools/list", %{}, sid)
    names = Enum.map(resp["result"]["tools"], & &1["name"])
    assert "hive_join" in names and "hive_next_task" in names and "hive_query" in names
    assert Enum.all?(resp["result"]["tools"], &(&1["inputSchema"]["type"] == "object"))

    {_, resp} = rpc(build_conn(), "no/such", %{}, sid)
    assert resp["error"]["code"] == -32601
  end

  test "notifications are accepted without a body", %{conn: conn} do
    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> post("/mcp", Jason.encode!(%{jsonrpc: "2.0", method: "notifications/initialized"}))

    assert conn.status == 202
  end

  test "two agents self-organise over MCP: plan, claim, share, finish", %{conn: conn} do
    planner = session(conn)
    worker = session(build_conn())

    {false, %{"agent" => %{"id" => p_id}}, _} =
      call(planner, "hive_join", %{name: "planner", skills: ["design"]})

    {false, %{"agent" => %{"id" => w_id}, "how_to_work" => brief}, _} =
      call(worker, "hive_join", %{name: "worker", skills: ["elixir"]})

    assert brief =~ "hive_next_task"
    refute p_id == w_id

    {false, %{"goal" => goal}, _} =
      call(planner, "hive_add_goal", %{title: "Add caching", priority: 4})

    {false, %{"task" => t1}, _} =
      call(planner, "hive_add_task", %{
        title: "Cache the planner output",
        goal: goal,
        skills: ["elixir"],
        acceptance: "hit rate reported"
      })

    {false, %{"task" => t2}, _} =
      call(planner, "hive_add_task", %{title: "Document the cache", goal: goal, depends_on: [t1]})

    {false, %{"decision" => _}, _} =
      call(planner, "hive_decide", %{
        text: "Use ETS, not Redis",
        rationale: "single node",
        about: [goal]
      })

    # The worker is attributed by its session, without passing agent_id.
    {false, work, text} = call(worker, "hive_next_task", %{})
    assert work["claimed"] and work["task"]["key"] == t1
    assert text =~ "Use ETS, not Redis", "decisions on the goal reach the worker's context pack"

    {false, _, _} = call(worker, "hive_progress", %{task: t1, note: "ETS table in place"})

    {false, %{"insight" => _}, _} =
      call(worker, "hive_share", %{
        text: "ETS read concurrency doubles throughput",
        confidence: 0.8,
        about: [t1]
      })

    # The planner cannot finish a task the worker holds.
    {true, _, err} = call(planner, "hive_finish", %{task: t1, summary: "stolen"})
    assert err =~ "held by #{w_id}"

    {false, %{"done" => true}, _} =
      call(worker, "hive_finish", %{
        task: t1,
        summary: "cached",
        artifacts: [%{uri: "lib/cache.ex"}]
      })

    assert Hive.task(t1).status == "done"
    assert Hive.task(t2).status == "open", "the dependent unblocks"

    {false, board, _} = call(planner, "hive_board", %{})
    assert [%{"title" => "Add caching", "done" => 1, "tasks" => 2}] = board["goals"]

    {false, %{"rows" => [[2]]}, _} =
      call(planner, "hive_query", %{cypher: "MATCH (t:HiveTask) RETURN count(t)"})

    {true, _, msg} = call(planner, "hive_query", %{cypher: "MATCH (t:HiveTask) DETACH DELETE t"})
    assert msg =~ "read-only"
  end

  test "questions and messages reach the right inbox", %{conn: conn} do
    a = session(conn)
    b = session(build_conn())
    {false, _, _} = call(a, "hive_join", %{name: "a", skills: ["elixir"]})

    {false, %{"agent" => %{"id" => b_id}}, _} =
      call(b, "hive_join", %{name: "b", skills: ["rust"]})

    {false, %{"question" => q}, _} =
      call(a, "hive_ask", %{text: "Is the NIF dirty-scheduled?", skills: ["rust"]})

    {false, _, _} = call(a, "hive_message", %{to: b_id, text: "ping"})

    {false, inbox, _} = call(b, "hive_inbox", %{})
    assert [%{"key" => ^q}] = inbox["questions"]
    assert [%{"text" => "ping"}] = inbox["messages"]

    {false, _, _} = call(b, "hive_answer", %{question: q, text: "Yes, DirtyCpu."})
    {false, inbox, _} = call(b, "hive_inbox", %{})
    assert inbox["questions"] == []
  end

  test "tools that act need an agent", %{conn: conn} do
    sid = session(conn)
    {true, _, msg} = call(sid, "hive_next_task", %{})
    assert msg =~ "hive_join"
  end

  test "resources and prompts", %{conn: conn} do
    sid = session(conn)
    {:ok, t} = Hive.add_task(%{title: "Readable as a resource"})

    {_, resp} = rpc(build_conn(), "resources/list", %{}, sid)
    uris = Enum.map(resp["result"]["resources"], & &1["uri"])
    assert "hive://board" in uris and ("hive://task/" <> t) in uris

    {_, resp} = rpc(build_conn(), "resources/read", %{uri: "hive://task/" <> t}, sid)
    assert hd(resp["result"]["contents"])["text"] =~ "# Task: Readable as a resource"

    {_, resp} =
      rpc(
        build_conn(),
        "prompts/get",
        %{name: "hive_planner", arguments: %{goal: "Ship v2"}},
        sid
      )

    assert hd(resp["result"]["messages"])["content"]["text"] =~ "Goal: Ship v2"
  end

  test "a token, when configured, is required", %{conn: conn} do
    Application.put_env(:jido_swarm, :mcp_token, "s3cret")
    {conn, _} = rpc(conn, "ping")
    assert conn.status == 401

    conn =
      build_conn()
      |> put_req_header("authorization", "Bearer s3cret")
      |> put_req_header("content-type", "application/json")
      |> post("/mcp", Jason.encode!(%{jsonrpc: "2.0", id: 1, method: "ping"}))

    assert conn.status == 200
  end

  describe "HiveWork applies a model's answer to the board" do
    setup do
      {:ok, me} = Hive.join(name: "w", kind: "worker")
      {:ok, t} = Hive.add_task(%{title: "Something"})
      {:ok, _} = Hive.claim(t, me.id)
      {:ok, me: me.id, t: t}
    end

    test "done, with insights and questions", %{me: me, t: t} do
      answer = %{
        "outcome" => "done",
        "summary" => "did it",
        "insights" => [%{"text" => "learned a thing", "confidence" => 0.9}],
        "questions" => [%{"text" => "who owns deploys?", "skills" => ["ops"]}]
      }

      assert {:ok, %{outcome: "done"}} = JidoSwarm.Actions.HiveWork.apply_answer(me, t, answer)
      assert Hive.task(t).status == "done"
      assert [%{text: "learned a thing", about: [^t]}] = Hive.insights()
      assert [%{text: "who owns deploys?"}] = Hive.questions()
    end

    test "decompose splits the task for others", %{me: me, t: t} do
      answer = %{
        "outcome" => "decompose",
        "subtasks" => [%{"title" => "a"}, %{"title" => "b", "depends_on" => [0]}]
      }

      assert {:ok, _} = JidoSwarm.Actions.HiveWork.apply_answer(me, t, answer)
      assert Hive.task(t).status == "split"
      assert length(Hive.task(t).subtasks) == 2
    end

    test "handoff returns it to the board with a note", %{me: me, t: t} do
      assert {:ok, _} =
               JidoSwarm.Actions.HiveWork.apply_answer(me, t, %{
                 "outcome" => "handoff",
                 "note" => "half done"
               })

      assert Hive.task(t).status == "open"
      {:ok, pack} = Hive.context(t)
      assert pack.markdown =~ "half done"
    end
  end
end
