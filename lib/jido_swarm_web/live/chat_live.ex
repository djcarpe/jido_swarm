defmodule JidoSwarmWeb.ChatLive do
  @moduledoc """
  The operator's view of the swarm: a conversation on the left, what the swarm
  is doing and what it knows on the right.

  Two sources of truth feed this, and they update differently:

  * **The queue** broadcasts on the `"swarm"` PubSub topic whenever a job is
    enqueued or completed, so pool activity appears immediately.
  * **The knowledge graph** has no change feed of its own here — findings arrive
    from other nodes over the mesh, not through this process — so it is
    re-read on a timer. A poll is the honest mechanism for something that can
    change without this node being involved.
  """

  use JidoSwarmWeb, :live_view

  alias JidoSwarm.Knowledge
  alias JidoSwarm.Swarm

  @refresh_interval 2_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(JidoSwarm.PubSub, "swarm")
      :timer.send_interval(@refresh_interval, self(), :refresh)
    end

    {:ok,
     socket
     |> assign(:pending_reply, nil)
     |> assign(:composer, "")
     |> assign(:tab, :findings)
     |> load()}
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
     |> put_flash(:info, "Queued #{count} jobs across #{length(JidoSwarm.Repos.all())} repositories.")
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
  def handle_info(_msg, socket), do: {:noreply, socket}

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
    |> assign_turns(graph_available?, graph)
  end

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

  @doc false
  def format_duration(nil), do: ""
  def format_duration(ms) when ms < 1000, do: "#{ms}ms"
  def format_duration(ms), do: "#{Float.round(ms / 1000, 1)}s"
end
