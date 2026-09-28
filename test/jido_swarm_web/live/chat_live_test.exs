defmodule JidoSwarmWeb.ChatLiveTest do
  use JidoSwarmWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  describe "the dashboard" do
    test "renders the swarm's state", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")

      assert html =~ "Jido Swarm"
      assert html =~ "Ask the swarm"
      # Every configured repository is offered for survey.
      for repo <- JidoSwarm.Repos.all(), do: assert(html =~ repo.name)
    end

    test "says which model is in use and whether it is reachable", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")
      assert html =~ "Ollama" or html =~ "Anthropic"
    end

    test "says publishing is unavailable without a token", %{conn: conn} do
      System.delete_env("GITHUB_TOKEN")
      {:ok, _view, html} = live(conn, ~p"/")

      assert html =~ "GITHUB_TOKEN"
    end

    test "switching tabs shows the matching pane", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert view |> element("button", "Proposals") |> render_click() =~ "No proposals yet"
      assert view |> element("button", "Attempts") |> render_click() =~ "No implementation"
    end

    test "the Hive tab shows the board and lets the operator add work", %{conn: conn} do
      tag = System.unique_integer([:positive])
      {:ok, view, _html} = live(conn, ~p"/")

      html = view |> element("button", "Hive") |> render_click()
      assert html =~ "claude mcp add --transport http hive"

      view |> element("button[phx-value-what=goal]") |> render_click()
      view |> form("#hive-goal", %{title: "UI goal #{tag}", priority: "4"}) |> render_submit()
      [goal] = Enum.filter(JidoSwarm.Hive.goals(), &(&1.title == "UI goal #{tag}"))
      assert goal.priority == 4
      # Submitting closes the dialog.
      refute has_element?(view, "#hive-goal")

      view |> element("button[phx-value-what=task]") |> render_click()

      html =
        view
        |> form("#hive-task", %{title: "UI task #{tag}", skills: "Elixir, UI", goal: goal.key})
        |> render_submit()

      assert html =~ "UI goal #{tag}"
      assert html =~ "UI task #{tag}"
      assert html =~ "open on the board"

      [task] = Enum.filter(JidoSwarm.Hive.tasks(), &(&1.title == "UI task #{tag}"))
      assert task.goal == goal.key and task.skills == ["elixir", "ui"]
      assert task.created_by == "operator"
    end

    test "a draft in the dialog survives the board refreshing underneath it", %{conn: conn} do
      tag = System.unique_integer([:positive])
      {:ok, view, _html} = live(conn, ~p"/")
      view |> element("button", "Hive") |> render_click()
      view |> element("button[phx-value-what=task]") |> render_click()

      view
      |> form("#hive-task", %{title: "half typed #{tag}", detail: "and a detail"})
      |> render_change()

      # Someone else changes the board; the feed makes the tab re-read and
      # re-render. The draft is state, so it is still there.
      {:ok, _} = JidoSwarm.Hive.add_goal(%{title: "Elsewhere #{tag}", created_by: "agent"})
      assert eventually(fn -> render(view) =~ "Elsewhere #{tag}" end)

      html = render(view)
      assert html =~ ~s(value="half typed #{tag}")
      assert html =~ "and a detail"
      assert has_element?(view, "#hive-modal.modal-open")

      # Escape closes it and the draft is kept for next time.
      render_keydown(view, "hive_close", %{"key" => "Escape"})
      refute has_element?(view, "#hive-modal.modal-open")
      view |> element("button[phx-value-what=task]") |> render_click()
      assert render(view) =~ ~s(value="half typed #{tag}")
    end

    test "a board change made elsewhere reaches the Hive tab through the feed", %{conn: conn} do
      tag = System.unique_integer([:positive])
      {:ok, view, _html} = live(conn, ~p"/")
      view |> element("button", "Hive") |> render_click()

      # Not through the form: an agent on another pod would write the same way,
      # and the console learns of it from the feed, not from a timer.
      {:ok, _} = JidoSwarm.Hive.add_goal(%{title: "Remote goal #{tag}", created_by: "agent"})

      assert eventually(fn -> render(view) =~ "Remote goal #{tag}" end)
    end

    test "the Hive tab says which replica this is and what is on the wire", %{conn: conn} do
      tag = System.unique_integer([:positive])
      {:ok, view, _html} = live(conn, ~p"/")

      html = view |> element("button", "Hive") |> render_click()
      origin = Jido.Context.Graph.origin(JidoSwarm.graph())
      assert html =~ "You are on"
      assert html =~ origin

      {:ok, _} = JidoSwarm.Hive.share("tester", %{text: "wire insight #{tag}"})

      # The ticker line: this pod's colour chip, the summary, and "here" for a
      # local write rather than a lag.
      assert eventually(fn ->
               html = render(view)
               html =~ "+insight &quot;wire insight #{tag}&quot;" and html =~ ~r/>\s*here\s*</
             end)
    end

    test "the canvas gets the graph, then every delta, and a node on request", %{conn: conn} do
      tag = System.unique_integer([:positive])
      {:ok, view, _html} = live(conn, ~p"/")
      me = Jido.Context.Graph.origin(JidoSwarm.graph())

      # The container is always in the DOM, so the hook survives tab changes.
      assert has_element?(view, "#hive-frame.hidden #hive-mind")
      view |> element("button", "Hive") |> render_click()
      assert has_element?(view, "#hive-frame #hive-mind")
      refute has_element?(view, "#hive-frame.hidden")

      # The hook asks for the snapshot when it mounts.
      render_hook(view, "hive_snapshot", %{})
      assert_push_event(view, "hive:snapshot", %{nodes: nodes, me: ^me, colors: colors})
      assert is_list(nodes) and is_map(colors)

      # A write anywhere becomes drawing instructions.
      {:ok, goal} = JidoSwarm.Hive.add_goal(%{title: "Canvas goal #{tag}", created_by: "agent"})
      assert_push_event(view, "hive:delta", %{origin: ^me, local: true, ops: ops}, 2_000)
      assert [%{op: "put_node", node: %{key: ^goal, kind: "goal", origin: ^me}}] = ops

      # Selecting a node opens the drawer with its stamp and properties.
      html = render_hook(view, "hive_select", %{"key" => goal})
      assert html =~ "Canvas goal #{tag}"
      assert html =~ "written by"
      assert html =~ ~r/seq \d+/
      assert html =~ "hive.board"
      assert_push_event(view, "hive:select", %{key: ^goal})

      # Asking for its surroundings patches the canvas.
      render_hook(view, "hive_expand_node", %{"key" => goal})
      assert_push_event(view, "hive:patch", %{nodes: _, edges: _})

      # Filters go straight to the hook.
      view
      |> form("#hive-filters", %{"kinds" => ["goal"], "window" => "60000"})
      |> render_change()

      assert_push_event(view, "hive:filter", %{
        kinds: ["goal"],
        window_ms: 60_000,
        remote_only: false
      })

      # Expanding is server state, so a re-render keeps it.
      html = view |> element("button", "expand") |> render_click()
      assert html =~ "hm-expanded"
      assert has_element?(view, "button", "close")

      refute render_hook(view, "hive_clear", %{}) =~ "hive-drawer"
    end

    test "explaining a task shows its pack and scores and lights the canvas", %{conn: conn} do
      tag = System.unique_integer([:positive])
      {:ok, view, _html} = live(conn, ~p"/")
      view |> element("button", "Hive") |> render_click()

      {:ok, task} = JidoSwarm.Hive.add_task(%{title: "Explain me #{tag}", created_by: "operator"})
      assert eventually(fn -> render(view) =~ "Explain me #{tag}" end)

      html = render_change(view, "hive_explain", %{"task" => task})
      assert html =~ "is handed"
      assert html =~ "Explain me #{tag}"
      assert html =~ "How each active agent scores it" or html =~ "No active agent"
      assert_push_event(view, "hive:highlight", %{keys: keys, label: label})
      assert task in keys and label =~ "Explain me"

      refute render_click(view, "hive_explain_clear", %{}) =~ "is handed"
    end

    test "the Glider tab reports instrumentation", %{conn: conn} do
      JidoSwarm.GliderMetrics.reset()
      {:ok, view, _html} = live(conn, ~p"/")

      # The dashboard reads the graph on every render, so by the time anyone
      # can click the tab there is always something recorded — the instrument
      # measures the app measuring itself, which is the honest reading.
      # Do some more graph work, then confirm it is reported.
      {:ok, _} = Jido.Context.assert(JidoSwarm.graph(), "ui:1", ["UiThing"], %{"v" => 1})
      {:ok, _} = Jido.Context.query(JidoSwarm.graph(), "MATCH (t:UiThing) RETURN t.v")

      html = view |> element("button", "Glider") |> render_click()

      assert html =~ "Operations"
      assert html =~ "Time in Glider"
      # The per-operation latency table.
      assert html =~ "p95"
      assert html =~ "query"
      # And the statement breakdown.
      assert html =~ "MATCH"
    end

    test "Glider load is visible in the header without opening the tab", %{conn: conn} do
      JidoSwarm.GliderMetrics.reset()
      {:ok, _} = Jido.Context.assert(JidoSwarm.graph(), "hdr:1", ["HdrThing"], %{})

      {:ok, _view, html} = live(conn, ~p"/")
      assert html =~ "ops"
    end

    test "a failing job explains itself instead of just saying failed", %{conn: conn} do
      # The exact shape a real org-scoped key produces. This presented to an
      # operator as "it keeps crashing" with nothing in the UI saying why.
      error =
        ~s({:http, 400, %{"error" => %{"message" => "This API key is not scoped to a workspace, ) <>
          ~s(so this request must include the anthropic-workspace-id header with the ID of the ) <>
          ~s(workspace to use.", "type" => "invalid_request_error"}}})

      explained = JidoSwarmWeb.ChatLive.explain_failure(error)

      assert explained =~ "organization-scoped"
      assert explained =~ "ANTHROPIC_WORKSPACE_ID"

      assert is_binary(conn.host)
    end

    test "explain_failure prefers the API's own message when it has one" do
      error = ~s({:http, 400, %{"error" => %{"message" => "Something specific went wrong here"}}})

      assert JidoSwarmWeb.ChatLive.explain_failure(error) == "Something specific went wrong here"
    end

    test "explain_failure names the common misconfigurations" do
      assert JidoSwarmWeb.ChatLive.explain_failure("no_github_token") =~ "GITHUB_TOKEN"
      assert JidoSwarmWeb.ChatLive.explain_failure("No Anthropic API key") =~ "ANTHROPIC_API_KEY"
      assert JidoSwarmWeb.ChatLive.explain_failure(nil) =~ "Unknown"
    end

    test "queueing a survey reports back", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      html =
        view |> element("button[phx-value-repo='jido'][phx-click='survey']") |> render_click()

      assert html =~ "Queued a survey of jido"
    end

    test "running a cycle queues one job per repository", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      html = view |> element("button", "Run a cycle") |> render_click()
      assert html =~ "Queued #{length(JidoSwarm.Repos.all())} jobs"
    end

    test "an empty message is ignored rather than dispatched", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      before = JidoSwarm.Swarm.Queue.stats()
      render_submit(element(view, "form"), %{"message" => "   "})

      assert JidoSwarm.Swarm.Queue.stats().pending == before.pending
    end
  end

  # The board refresh is debounced, so give the feed and the timer a moment.
  defp eventually(fun, tries \\ 20) do
    cond do
      fun.() ->
        true

      tries == 0 ->
        false

      true ->
        Process.sleep(100)
        eventually(fun, tries - 1)
    end
  end
end
