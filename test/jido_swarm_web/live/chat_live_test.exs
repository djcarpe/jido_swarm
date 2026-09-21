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

    test "queueing a survey reports back", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      html = view |> element("button[phx-value-repo='jido'][phx-click='survey']") |> render_click()
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
end
