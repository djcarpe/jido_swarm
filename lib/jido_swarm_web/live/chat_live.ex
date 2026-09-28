defmodule JidoSwarmWeb.ChatLive do
  @moduledoc """
  The operator's view of the swarm: a conversation on the left, what the swarm
  is doing and what it knows on the right.

  Two sources of truth feed this, and they update differently:

  * **The queue** broadcasts on the `"swarm"` PubSub topic whenever a job is
    enqueued or completed, so pool activity appears immediately.
  * **The knowledge graph** changes without this process being involved —
    findings arrive from other nodes over the mesh — so the older panes are
    re-read on a timer.
  * **The Hive board** is read when the graph changes: `JidoSwarm.Hive.Feed`
    rebroadcasts every mesh delta on the `"hive"` PubSub topic, and a delta on
    a Hive topic schedules one re-read, debounced so a burst of writes is one
    render. A slow tick remains because a task's status is partly a matter of
    time — a lease expires without any delta being written.
  """

  use JidoSwarmWeb, :live_view

  import JidoSwarmWeb.HiveComponents

  alias JidoSwarm.Hive.Canvas
  alias JidoSwarm.Hive.Feed
  alias JidoSwarm.Knowledge
  alias JidoSwarm.Swarm

  @refresh_interval 2_000
  @hive_debounce 500
  @hive_tick 10_000
  @peers_interval 5_000
  @ticker_length 30

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(JidoSwarm.PubSub, "swarm")
      Phoenix.PubSub.subscribe(JidoSwarm.PubSub, "hive")
      :timer.send_interval(@refresh_interval, self(), :refresh)
      :timer.send_interval(@hive_tick, self(), :hive_tick)
      :timer.send_interval(@peers_interval, self(), :hive_peers)
    end

    {:ok,
     socket
     |> assign(:pending_reply, nil)
     |> assign(:composer, "")
     |> assign(:tab, :findings)
     |> assign(:hive_refresh_pending?, false)
     |> assign(:selected, nil)
     |> assign(:filters, default_filters())
     |> assign(:expanded?, false)
     |> load()
     |> load_hive()
     |> load_mesh()
     |> poll_peers()}
  end

  # ===========================================================================
  # Events
  # ===========================================================================

  @impl true
  def handle_event("send", %{"message" => message}, socket) do
    message = String.trim(message)

    if message == "" do
      {:noreply, socket}
    else
      graph_available? = socket.assigns.graph_available?

      if graph_available? do
        Knowledge.add_chat_turn(JidoSwarm.graph(), %{role: :user, body: message})
      end

      {:ok, job} = Swarm.chat(message, self())

      {:noreply,
       socket
       |> assign(:pending_reply, job.id)
       |> assign(:composer, "")
       |> append_local_turn(%{role: "user", body: message, worker: "", at: now()})
       |> load()}
    end
  end

  def handle_event("compose", %{"message" => message}, socket) do
    {:noreply, assign(socket, :composer, message)}
  end

  def handle_event("run_cycle", _params, socket) do
    {:ok, count} = Swarm.run_cycle()

    {:noreply,
     socket
     |> put_flash(
       :info,
       "Queued #{count} jobs across #{length(JidoSwarm.Repos.all())} repositories."
     )
     |> load()}
  end

  def handle_event("survey", %{"repo" => repo}, socket) do
    {:ok, _} = Swarm.survey(repo)
    {:noreply, socket |> put_flash(:info, "Queued a survey of #{repo}.") |> load()}
  end

  def handle_event("propose", %{"repo" => repo}, socket) do
    {:ok, _} = Swarm.propose(repo)
    {:noreply, socket |> put_flash(:info, "Queued a proposal for #{repo}.") |> load()}
  end

  def handle_event("implement", %{"key" => key}, socket) do
    {:ok, _} = Swarm.implement(key)

    {:noreply,
     socket
     |> put_flash(:info, "Queued an implementation. Watch the attempts tab.")
     |> load()}
  end

  def handle_event("tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, :tab, String.to_existing_atom(tab))}
  end

  # The operator steers the Hive the same way any agent does: by adding work to
  # the board. Nothing is assigned; agents pick it up by themselves.
  def handle_event("hive_add_goal", %{"title" => title} = params, socket) do
    case String.trim(title) do
      "" ->
        {:noreply, put_flash(socket, :error, "A goal needs a title.")}

      title ->
        {:ok, _} =
          JidoSwarm.Hive.add_goal(%{
            title: title,
            description: String.trim(params["description"] || ""),
            priority: params["priority"] || "3",
            created_by: "operator"
          })

        {:noreply, socket |> put_flash(:info, "Goal added to the board.") |> load_hive()}
    end
  end

  def handle_event("hive_add_task", %{"title" => title} = params, socket) do
    case String.trim(title) do
      "" ->
        {:noreply, put_flash(socket, :error, "A task needs a title.")}

      title ->
        {:ok, _} =
          JidoSwarm.Hive.add_task(%{
            title: title,
            detail: String.trim(params["detail"] || ""),
            goal: blank_to_nil(params["goal"]),
            skills: params["skills"] || "",
            priority: params["priority"] || "3",
            created_by: "operator"
          })

        {:noreply,
         socket |> put_flash(:info, "Task added. An idle agent will pick it up.") |> load_hive()}
    end
  end

  # ---------------------------------------------------------------------------
  # The canvas
  # ---------------------------------------------------------------------------

  # The hook asks for the graph when it mounts and again after a reconnect,
  # so the picture is rebuilt from the graph rather than from what the
  # browser remembers.
  def handle_event("hive_snapshot", _params, socket) do
    {:noreply, push_snapshot(socket)}
  end

  def handle_event("hive_select", %{"key" => key}, socket) do
    selected = if key in [nil, ""], do: nil, else: canvas(fn -> Canvas.detail(key) end)

    {:noreply,
     socket
     |> assign(:selected, selected)
     |> push_event("hive:select", %{key: selected && selected.node.key})}
  end

  def handle_event("hive_clear", _params, socket) do
    {:noreply, socket |> assign(:selected, nil) |> push_event("hive:select", %{key: nil})}
  end

  def handle_event("hive_expand_node", %{"key" => key}, socket) do
    case canvas(fn -> Canvas.neighbours(key) end) do
      nil -> {:noreply, socket}
      around -> {:noreply, push_event(socket, "hive:patch", around)}
    end
  end

  def handle_event("hive_filter", params, socket) do
    filters = %{
      kinds: List.wrap(params["kinds"]) |> Enum.reject(&(&1 == "")),
      origins: List.wrap(params["origin"]) |> Enum.reject(&(&1 == "")),
      window_ms: parse_window(params["window"]),
      remote_only: params["remote_only"] in ["on", "true"]
    }

    {:noreply, socket |> assign(:filters, filters) |> push_event("hive:filter", filters)}
  end

  def handle_event("hive_toggle_expand", _params, socket) do
    {:noreply, assign(socket, :expanded?, not socket.assigns.expanded?)}
  end

  def handle_event("reset_metrics", _params, socket) do
    JidoSwarm.GliderMetrics.reset()
    {:noreply, socket |> put_flash(:info, "Glider metrics cleared.") |> load()}
  end

  # ===========================================================================
  # Messages
  # ===========================================================================

  @impl true
  def handle_info({:swarm_reply, job_id, result}, socket) do
    socket =
      case result do
        {:ok, %{answer: answer}} ->
          append_local_turn(socket, %{
            role: "assistant",
            body: answer,
            worker: "",
            at: now()
          })

        {:ok, _other} ->
          socket

        {:error, reason} ->
          append_local_turn(socket, %{
            role: "assistant",
            body: "The swarm could not answer: #{inspect(reason)}",
            worker: "",
            at: now()
          })
      end

    socket =
      if socket.assigns.pending_reply == job_id,
        do: assign(socket, :pending_reply, nil),
        else: socket

    {:noreply, load(socket)}
  end

  def handle_info({:swarm_event, _event}, socket), do: {:noreply, load(socket)}
  def handle_info(:refresh, socket), do: {:noreply, load(socket)}

  # A delta from anywhere in the mesh goes on the ticker at once; a change to
  # the board also re-reads it, one re-read per burst — the first delta starts
  # the clock, the rest ride along.
  def handle_info({:hive_delta, entry}, socket) do
    socket = socket |> tick(entry) |> push_delta(entry)

    case entry.topic do
      "hive." <> _ -> {:noreply, schedule_hive_refresh(socket)}
      _ -> {:noreply, socket}
    end
  end

  def handle_info({:hive_burst, _count}, socket) do
    {:noreply, socket |> load_mesh() |> push_snapshot() |> schedule_hive_refresh()}
  end

  def handle_info(:hive_refresh, socket) do
    {:noreply, socket |> assign(:hive_refresh_pending?, false) |> load_hive()}
  end

  def handle_info(:hive_tick, socket), do: {:noreply, load_hive(socket)}
  def handle_info(:hive_peers, socket), do: {:noreply, poll_peers(socket)}
  def handle_info(_msg, socket), do: {:noreply, socket}

  # Asking the other pods what they have seen is a network round trip, so it
  # runs off the render path with a short timeout; a partitioned pod reads as
  # unreachable rather than freezing the page.
  @impl true
  def handle_async(:hive_peers, {:ok, {peers, authorship, heat}}, socket) do
    mesh = %{socket.assigns.mesh | peers: peers, authorship: authorship}
    {:noreply, socket |> assign(:mesh, mesh) |> push_event("hive:heat", heat)}
  end

  def handle_async(:hive_peers, _failed, socket), do: {:noreply, socket}

  defp schedule_hive_refresh(%{assigns: %{hive_refresh_pending?: true}} = socket), do: socket

  defp schedule_hive_refresh(socket) do
    Process.send_after(self(), :hive_refresh, @hive_debounce)
    assign(socket, :hive_refresh_pending?, true)
  end

  # ===========================================================================
  # Loading
  # ===========================================================================

  defp load(socket) do
    status = Swarm.status()
    graph_available? = JidoSwarm.graph_available?()
    graph = JidoSwarm.graph()

    socket
    |> assign(:status, status)
    |> assign(:graph_available?, graph_available?)
    |> assign(:summary, if(graph_available?, do: Knowledge.summary(graph), else: empty_summary()))
    |> assign(:findings, if(graph_available?, do: Knowledge.findings(graph), else: []))
    |> assign(:proposals, if(graph_available?, do: Knowledge.proposals(graph), else: []))
    |> assign(:attempts, if(graph_available?, do: Knowledge.attempts(graph), else: []))
    |> assign(:repos, JidoSwarm.Repos.all())
    |> assign(:glider, JidoSwarm.GliderMetrics.snapshot())
    |> assign_turns(graph_available?, graph)
  end

  # The board is read on its own schedule — when the feed says it changed, and
  # slowly otherwise for leases running out — so it lives outside `load/1`.
  defp load_hive(socket) do
    hive = if JidoSwarm.graph_available?(), do: hive_digest(), else: empty_hive()
    assign(socket, :hive, hive)
  end

  defp hive_digest do
    JidoSwarm.Hive.digest(limit: 12)
  rescue
    _ -> empty_hive()
  catch
    :exit, _ -> empty_hive()
  end

  # ---------------------------------------------------------------------------
  # The mesh: this replica, the origins it has heard from, the wire
  # ---------------------------------------------------------------------------

  # Everything the feed already holds, read in one go: on mount, and again
  # after a burst, when the ticker would otherwise have skipped the middle.
  defp load_mesh(socket) do
    mesh =
      if feed_up?() do
        me = Feed.me()
        origins = Feed.origins()
        recent = Feed.recent(@ticker_length)
        previous = socket.assigns[:mesh]

        %{
          me: me,
          origins: origins,
          recent: recent,
          peers: (previous && previous.peers) || [],
          authorship: (previous && previous.authorship) || empty_authorship(),
          colors: colors(origins, recent, me.origin)
        }
      else
        empty_mesh()
      end

    assign(socket, :mesh, mesh)
  rescue
    _ -> assign(socket, :mesh, empty_mesh())
  catch
    :exit, _ -> assign(socket, :mesh, empty_mesh())
  end

  # One delta onto the ticker. Origins are re-read from the feed: it is one
  # call, and it is how a pod heard from for the first time gets its colour.
  defp tick(%{assigns: %{mesh: %{me: %{origin: me}} = mesh}} = socket, entry) do
    recent = Enum.take([entry | mesh.recent], @ticker_length)
    origins = Feed.origins()

    assign(socket, :mesh, %{
      mesh
      | recent: recent,
        origins: origins,
        colors: colors(origins, recent, me)
    })
  rescue
    _ -> socket
  catch
    :exit, _ -> socket
  end

  defp tick(socket, _entry), do: load_mesh(socket)

  defp poll_peers(%{assigns: %{mesh: %{me: %{origin: me}}}} = socket) do
    if connected?(socket) do
      start_async(socket, :hive_peers, fn ->
        {Feed.peers(), Canvas.authorship(me), JidoSwarm.Hive.Memory.heat()}
      end)
    else
      socket
    end
  end

  defp poll_peers(socket), do: socket

  defp colors(origins, recent, me) do
    (Enum.map(origins, & &1.origin) ++ Enum.map(recent, & &1.origin))
    |> Canvas.origin_colors(me)
  end

  defp feed_up?, do: JidoSwarm.graph_available?() and is_pid(Process.whereis(Feed))

  # The whole picture, for the hook: the newest entities, this replica's
  # origin so the hook knows what "here" means, and the colours it draws in.
  defp push_snapshot(%{assigns: %{mesh: %{me: %{origin: me}, colors: colors}}} = socket) do
    case canvas(fn -> Canvas.snapshot() end) do
      nil ->
        socket

      snapshot ->
        push_event(socket, "hive:snapshot", Map.merge(snapshot, %{me: me, colors: colors}))
    end
  end

  defp push_snapshot(socket), do: socket

  defp push_delta(%{assigns: %{mesh: %{colors: colors}}} = socket, %{draw: ops} = entry) do
    push_event(socket, "hive:delta", %{
      id: entry.id,
      origin: entry.origin,
      local: entry.local,
      ops: ops,
      colors: colors
    })
  end

  defp push_delta(socket, _entry), do: socket

  # A read for the canvas is never allowed to take the page down with it.
  defp canvas(fun) do
    fun.()
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp default_filters, do: %{kinds: [], origins: [], window_ms: nil, remote_only: false}

  defp parse_window(value) when value in [nil, "", "all"], do: nil

  defp parse_window(value) do
    case Integer.parse(value) do
      {ms, _} when ms > 0 -> ms
      _ -> nil
    end
  end

  defp empty_mesh do
    %{me: nil, origins: [], recent: [], peers: [], authorship: empty_authorship(), colors: %{}}
  end

  defp empty_authorship do
    %{nodes: %{}, edges: %{}, total_nodes: 0, total_edges: 0, remote_share: nil}
  end

  defp empty_hive do
    %{
      goals: [],
      counts: %{},
      in_flight: [],
      open: [],
      blocked: [],
      open_questions: [],
      recent_insights: [],
      agents: []
    }
  end

  defp blank_to_nil(v) when v in [nil, ""], do: nil
  defp blank_to_nil(v), do: v

  # The graph is the conversation's home, so every browser sees the same
  # history. Before it exists, turns are kept in the socket alone.
  defp assign_turns(socket, true, graph) do
    assign(socket, :turns, Knowledge.chat_turns(graph, 100))
  end

  defp assign_turns(socket, false, _graph) do
    assign_new(socket, :turns, fn -> [] end)
  end

  defp append_local_turn(socket, turn) do
    if socket.assigns[:graph_available?] do
      socket
    else
      assign(socket, :turns, (socket.assigns[:turns] || []) ++ [turn])
    end
  end

  defp empty_summary, do: %{repos: 0, findings: 0, proposals: 0, attempts: 0, graph: %{}}

  defp now, do: System.system_time(:millisecond)

  # ===========================================================================
  # Helpers used by the template
  # ===========================================================================

  @doc false
  def active_provider(status) do
    Enum.find(status.providers, & &1.active?) || %{name: "none", ready?: false, hint: ""}
  end

  @doc false
  def status_tone(true), do: "badge-success"
  def status_tone(false), do: "badge-error"

  @doc false
  def attempt_tone(status) do
    cond do
      status in ["pr_opened", "tests_passed", "committed"] -> "badge-success"
      status in ["failed", "tests_failed", "publish_failed"] -> "badge-error"
      true -> "badge-warning"
    end
  end

  @doc false
  def proposal_tone("pr_opened"), do: "badge-success"
  def proposal_tone("implemented"), do: "badge-info"
  def proposal_tone(_), do: "badge-ghost"

  @doc false
  def format_time(nil), do: ""

  def format_time(ms) when is_integer(ms) do
    ms
    |> DateTime.from_unix!(:millisecond)
    |> Calendar.strftime("%H:%M:%S")
  end

  def format_time(_), do: ""

  @doc false
  def chat_side(%{role: "user"}), do: "chat-end"
  def chat_side(_), do: "chat-start"

  @doc false
  def chat_tone(%{role: "user"}), do: "chat-bubble-primary"
  def chat_tone(_), do: ""

  @doc """
  Turns a raw job error into a sentence worth showing an operator.

  The API's own message is usually the most accurate description available, so
  it is preferred over anything invented here — but a few recur often enough,
  and read obscurely enough, to be worth naming with the fix attached. The
  workspace one in particular presents as "every job fails" with nothing in the
  UI explaining why.
  """
  @spec explain_failure(String.t() | nil) :: String.t()
  def explain_failure(nil), do: "Unknown error."

  def explain_failure(error) do
    cond do
      error =~ "not scoped to a workspace" ->
        "The Anthropic API key is organization-scoped, so it needs a workspace. " <>
          "Set ANTHROPIC_WORKSPACE_ID in the jido-swarm Secret, or use a workspace-scoped key."

      error =~ "not_configured" or error =~ "No Anthropic API key" ->
        "No model is configured. Set ANTHROPIC_API_KEY in the jido-swarm Secret."

      error =~ "authentication_error" or error =~ "invalid x-api-key" ->
        "The Anthropic API key was rejected. Check ANTHROPIC_API_KEY."

      error =~ "no_github_token" ->
        "Pushing needs GITHUB_TOKEN. Implementation and tests still run without it."

      error =~ "exceed_context_size" ->
        "The prompt exceeded the model's context window."

      error =~ "no_findings" ->
        "Nothing has been learned about that repository yet — run a survey first."

      # An API message is usually more accurate than anything guessed here.
      true ->
        case Regex.run(~r/"message" => "([^"]{10,300})"/, error) do
          [_, message] -> message
          _ -> String.slice(error, 0, 300)
        end
    end
  end

  @doc """
  Microseconds as something a person can read at a glance.

  Graph work spans six orders of magnitude — an indexed lookup is single-digit
  microseconds, a whole-graph algorithm is seconds — so a fixed unit would make
  most of the column unreadable.
  """
  @spec format_us(integer() | nil) :: String.t()
  def format_us(nil), do: "—"
  def format_us(0), do: "0"
  def format_us(us) when us < 1_000, do: "#{us}µs"
  def format_us(us) when us < 1_000_000, do: "#{Float.round(us / 1_000, 1)}ms"
  def format_us(us), do: "#{Float.round(us / 1_000_000, 2)}s"

  @doc "Large counts, abbreviated."
  @spec format_count(integer() | nil) :: String.t()
  def format_count(nil), do: "0"
  def format_count(n) when n < 1_000, do: Integer.to_string(n)
  def format_count(n) when n < 1_000_000, do: "#{Float.round(n / 1_000, 1)}k"
  def format_count(n), do: "#{Float.round(n / 1_000_000, 2)}M"

  @doc """
  A sparkline over the per-second series, as inline SVG polyline points.

  Drawn rather than charted: it is a shape, not a figure to read values off,
  and a charting library would be several hundred kilobytes for one line.
  """
  @spec sparkline([map()], atom(), pos_integer(), pos_integer()) :: String.t()
  def sparkline(series, field, width \\ 240, height \\ 32)
  def sparkline([], _field, _width, _height), do: ""

  def sparkline(series, field, width, height) do
    values = Enum.map(series, &Map.get(&1, field, 0))
    max = Enum.max(values, fn -> 0 end)
    count = length(values)

    # A flat line along the bottom is the honest rendering of "nothing
    # happened", and it avoids dividing by zero.
    # Kept as floats throughout: with a single sample `step` would otherwise be
    # the integer width, and `index * step` an integer, which Float.round/2
    # rejects — a one-point series is exactly what a freshly started pod has.
    scale = if max > 0, do: max * 1.0, else: 1.0
    step = if count > 1, do: width / (count - 1), else: width * 1.0

    values
    |> Enum.with_index()
    |> Enum.map_join(" ", fn {value, index} ->
      x = Float.round(index * step, 1)
      y = Float.round(height - value / scale * (height - 2) - 1.0, 1)
      "#{x},#{y}"
    end)
  end

  @doc "Error rate as a tone, so a bad row is visible without reading numbers."
  @spec error_tone(number()) :: String.t()
  def error_tone(rate) when rate >= 10, do: "text-error font-semibold"
  def error_tone(rate) when rate > 0, do: "text-warning"
  def error_tone(_), do: "opacity-60"

  @doc "Percent of a goal's tasks that are done."
  @spec progress(map()) :: non_neg_integer()
  def progress(%{tasks: 0}), do: 0
  def progress(%{tasks: t, done: d}), do: round(d * 100 / t)

  @doc "Time left on a lease, for the in-flight list."
  @spec lease_left(integer() | nil) :: String.t()
  def lease_left(nil), do: ""

  def lease_left(until) do
    case div(until - now(), 1000) do
      s when s <= 0 -> "expiring"
      s when s < 60 -> "#{s}s left"
      s -> "#{div(s, 60)}m left"
    end
  end

  @doc "A board status as a badge tone."
  @spec hive_badge(String.t()) :: String.t()
  def hive_badge("open"), do: "badge-info"
  def hive_badge("claimed"), do: "badge-warning"
  def hive_badge("done"), do: "badge-success"
  def hive_badge("failed"), do: "badge-error"
  def hive_badge(_), do: "badge-ghost"

  @doc "How to connect an MCP client to this node."
  @spec mcp_url() :: String.t()
  def mcp_url, do: JidoSwarmWeb.Endpoint.url() <> "/mcp"

  @doc false
  def format_duration(nil), do: ""
  def format_duration(ms) when ms < 1000, do: "#{ms}ms"
  def format_duration(ms), do: "#{Float.round(ms / 1000, 1)}s"
end
