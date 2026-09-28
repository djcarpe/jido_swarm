defmodule JidoSwarmWeb.HiveComponents do
  @moduledoc """
  The parts of the console that show the Hive as a *shared* memory.

  The board lists say what the swarm is doing. These say where it comes from:
  which pod wrote what, whether the replicas agree, and the deltas arriving
  as they happen. Every origin keeps one colour across all of them, so a chip
  in the strip, a line in the ticker and a node on the canvas are recognisably
  the same pod.
  """

  use Phoenix.Component

  alias Phoenix.LiveView.JS

  @doc """
  This replica, how much of its memory came from elsewhere, and every origin
  it has heard from.
  """
  attr :mesh, :map, required: true

  def replica_strip(assigns) do
    ~H"""
    <div class="space-y-2">
      <div class="flex items-baseline justify-between gap-2">
        <div class="text-xs">
          <span class="opacity-60">You are on</span>
          <span class="font-mono font-semibold" style={"color: #{color(@mesh, @mesh.me.origin)}"}>
            {@mesh.me.origin}
          </span>
        </div>
        <div
          :if={@mesh.authorship.remote_share}
          class="text-right"
          title="Share of this replica's nodes stamped with another pod's origin"
        >
          <span class="text-2xl font-semibold tabular-nums">
            {percent(@mesh.authorship.remote_share)}
          </span>
          <span class="text-xs opacity-60">written elsewhere</span>
        </div>
      </div>

      <div class="flex flex-wrap gap-1">
        <span
          :for={o <- @mesh.origins}
          class="badge badge-sm gap-1 font-mono"
          style={"border-color: #{color(@mesh, o.origin)}; color: #{color(@mesh, o.origin)}"}
          title={origin_title(o)}
        >
          <span
            class="inline-block w-2 h-2 rounded-full"
            style={"background: #{color(@mesh, o.origin)}"}
          ></span>
          {o.origin}
          <span class="opacity-70">
            {o.deltas}Δ · seq {o.last_seq}{if o.lag_p50_ms, do: " · ~#{o.lag_p50_ms}ms"}
          </span>
          <span :if={Map.get(o, :superseded, 0) + Map.get(o, :tombstoned, 0) > 0} class="text-error">
            {Map.get(o, :superseded, 0) + Map.get(o, :tombstoned, 0)} lost
          </span>
        </span>
        <span :if={@mesh.origins == []} class="text-xs opacity-60">
          No deltas yet. The first write, from any pod, appears here.
        </span>
      </div>

      <.convergence :if={length(@mesh.peers) > 1} peers={@mesh.peers} mesh={@mesh} />
    </div>
    """
  end

  # Rows are replicas, columns are origins, cells are the highest sequence
  # each replica holds from that origin. Equal columns mean every pod has seen
  # the same writes — convergence you can read off a table.
  attr :peers, :list, required: true
  attr :mesh, :map, required: true

  defp convergence(assigns) do
    origins =
      assigns.peers
      |> Enum.flat_map(fn
        %{seen: seen} when is_map(seen) -> Map.keys(seen)
        _ -> []
      end)
      |> Enum.uniq()
      |> Enum.sort()

    reachable = Enum.filter(assigns.peers, &is_map(&1.seen))

    converged? =
      length(reachable) > 1 and
        reachable |> Enum.map(&Map.take(&1.seen, origins)) |> Enum.uniq() |> length() == 1

    assigns = assign(assigns, origins: origins, converged?: converged?)

    ~H"""
    <div class="text-xs">
      <div class="flex items-center gap-2 mb-1">
        <span class="opacity-60">Replicas</span>
        <span :if={@converged?} class="badge badge-xs badge-success">converged</span>
        <span :if={not @converged?} class="badge badge-xs badge-warning">catching up</span>
      </div>
      <table class="table table-xs font-mono">
        <thead>
          <tr>
            <th class="font-normal opacity-60">replica</th>
            <th
              :for={o <- @origins}
              class="font-normal text-right"
              style={"color: #{color(@mesh, o)}"}
            >
              {o}
            </th>
          </tr>
        </thead>
        <tbody>
          <tr :for={p <- @peers}>
            <td title={inspect(p.node)}>
              {p.origin || "?"}<span :if={p.local?} class="opacity-60"> (you)</span>
            </td>
            <td :for={o <- @origins} class="text-right tabular-nums">
              {cell(p.seen, o)}
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  @doc """
  Proof on demand: ping the mesh and watch the other pods answer through the
  graph, or write one key from two pods and see which write survives.
  """
  attr :mesh, :map, required: true
  attr :probes, :list, default: []
  attr :conflict, :any, default: nil

  def probe_panel(assigns) do
    reachable = Enum.filter(assigns.mesh.peers, &(not &1.local? and &1.connected?))
    assigns = assign(assigns, reachable: reachable, latest: List.first(assigns.probes))

    ~H"""
    <div class="space-y-1 text-xs">
      <div class="flex flex-wrap items-center gap-1">
        <button
          class="btn btn-xs btn-outline"
          phx-click="hive_probe"
          disabled={@reachable == []}
          title={
            if @reachable == [],
              do: "No other replica is connected; a probe would have nobody to answer it.",
              else:
                "Write a probe node here and time every other pod's acknowledgement, written back through the graph."
          }
        >
          ping the mesh
        </button>
        <button
          class="btn btn-xs btn-outline"
          phx-click="hive_conflict"
          disabled={@reachable == []}
          title="Write the same key from this pod and another, and see which write every replica keeps."
        >
          race two writes
        </button>
        <span :if={@reachable == []} class="opacity-60">
          one replica — connect another pod to try these
        </span>
      </div>

      <div :if={@latest} id="hive-probe" class="font-mono">
        <span class="opacity-60">probe {@latest.id} ·</span>
        <span :if={@latest.acks == [] and not @latest.timed_out}>waiting…</span>
        <span :if={@latest.acks != []}>
          {length(@latest.acks)} of {max(length(@latest.expected), length(@latest.acks))} answered
        </span>
        <span :if={@latest.timed_out} class="text-warning">
          · {length(@latest.expected) - length(@latest.acks)} did not answer in 5s
        </span>
        <div :for={ack <- @latest.acks} class="pl-2">
          <span
            class="inline-block w-2 h-2 rounded-full"
            style={"background: #{color(@mesh, ack.origin)}"}
          ></span>
          <span style={"color: #{color(@mesh, ack.origin)}"}>{ack.origin}</span>
          <span class="opacity-70">
            round trip {ack.rtt_ms}ms{if ack.one_way_ms, do: " · one way ~#{ack.one_way_ms}ms"}
          </span>
        </div>
      </div>

      <div :if={@conflict} id="hive-conflict" class="border-l-2 border-base-300 pl-2">
        <%= case @conflict do %>
          <% %{error: reason} -> %>
            <span class="text-warning">The race could not run: {reason}</span>
          <% %{winner: winner, loser: loser, explanation: explanation, key: key} -> %>
            <span class="font-mono">{key}</span>
            <span class="opacity-60">was written from</span>
            <span class="font-mono" style={"color: #{color(@mesh, winner.origin)}"}>{winner.origin}</span>
            <span class="opacity-60">and</span>
            <span class="font-mono" style={"color: #{color(@mesh, loser.origin)}"}>{loser.origin}</span>
            <span class="opacity-60">at once.</span>
            <span>
              Every replica kept <span
                class="font-mono"
                style={"color: #{color(@mesh, winner.origin)}"}
              >{winner.origin}</span>'s.
            </span>
            <div class="opacity-70">{explanation}</div>
          <% _ -> %>
            <span class="opacity-60">racing…</span>
        <% end %>
      </div>
    </div>
    """
  end

  @sections [
    task: "Task",
    why: "Why",
    handoffs: "Handoffs",
    inputs: "Inputs",
    decisions: "Decisions",
    knowledge: "Knowledge",
    questions: "Questions",
    around: "Around"
  ]

  @doc """
  What an agent would be handed for a task, and how every agent scores it:
  the context pack section by section, and the rule's arithmetic per agent.
  """
  attr :hive, :map, required: true
  attr :explain, :any, default: nil
  attr :mesh, :map, required: true

  def explain_panel(assigns) do
    assigns = assign(assigns, sections: @sections)

    ~H"""
    <div id="hive-explain" class="space-y-1 text-xs">
      <form id="hive-explain-form" phx-change="hive_explain" class="flex items-center gap-1">
        <span class="opacity-60">Explain</span>
        <select name="task" class="select select-bordered select-xs flex-1">
          <option value="">pick a task…</option>
          <option
            :for={t <- @hive.in_flight ++ @hive.open}
            value={t.key}
            selected={@explain && @explain.task.key == t.key}
          >
            {t.title}
          </option>
        </select>
        <button
          :if={@explain}
          type="button"
          class="btn btn-xs btn-ghost"
          phx-click="hive_explain_clear"
        >
          clear
        </button>
      </form>

      <div :if={@explain} class="space-y-2">
        <div class="opacity-60">
          What an agent picking <span class="font-mono">{@explain.task.key}</span>
          is handed — {byte_size(@explain.pack.markdown)} characters from {length(@explain.keys)} entities,
          lit on the canvas.
        </div>
        <div :for={{section, title} <- @sections} :if={@explain.pack.sections[section] != ""}>
          <details class="collapse collapse-arrow bg-base-200/40 rounded-box">
            <summary class="collapse-title min-h-0 py-1 px-2 text-xs">
              {title}
              <span class="opacity-60">· {length(@explain.pack.sources[section] || [])} entities</span>
            </summary>
            <div class="collapse-content px-2">
              <pre class="whitespace-pre-wrap font-mono text-[11px] opacity-80">{@explain.pack.sections[section]}</pre>
            </div>
          </details>
        </div>

        <div :if={@explain.scores != []} class="space-y-1">
          <div class="opacity-60">
            How each active agent scores it (the pick adds up to 1 point of jitter)
          </div>
          <div :for={row <- @explain.scores} class="space-y-0.5">
            <div class="flex justify-between gap-2">
              <span>
                <span class="font-mono">{row.name}</span>
                <span class="opacity-60">{Enum.join(row.skills, ", ")}</span>
                <span :if={not row.eligible} class="badge badge-xs badge-ghost">not eligible</span>
              </span>
              <span class="font-mono tabular-nums">{row.score}</span>
            </div>
            <div class="flex h-1.5 rounded overflow-hidden bg-base-300" title={why_title(row.why)}>
              <div class="bg-primary" style={"width: #{bar(row.why.priority * 10, row.score)}%"}>
              </div>
              <div class="bg-success" style={"width: #{bar(row.why.skill_fit * 6, row.score)}%"}>
              </div>
              <div class="bg-info" style={"width: #{bar(row.why.record * 2, row.score)}%"}></div>
              <div class="bg-warning" style={"width: #{bar(row.why.neglect, row.score)}%"}></div>
            </div>
          </div>
          <div class="opacity-60">
            <span class="text-primary">■</span>
            priority <span class="text-success">■</span>
            skill fit <span class="text-info">■</span>
            record <span class="text-warning">■</span>
            neglect · heat and failures subtract
          </div>
        </div>
        <div :if={@explain.scores == []} class="opacity-60">No active agent to score it.</div>
      </div>
    </div>
    """
  end

  defp bar(part, score) when score > 0, do: Float.round(min(max(part / score, 0), 1) * 100, 1)
  defp bar(_, _), do: 0

  defp why_title(why) do
    "priority #{why.priority}×10 · skill fit #{why.skill_fit}×6 · record #{why.record}×2 · " <>
      "neglect +#{why.neglect} · heat −#{why.heat}×3 · failures −#{why.my_failures}×15"
  end

  @doc """
  Take the memory with you: this replica's graph as JSON Lines, whole or by
  what it was published as.
  """
  attr :summary, :map, required: true

  def export_links(assigns) do
    assigns = assign(assigns, scopes: JidoSwarm.Knowledge.Export.scopes())

    ~H"""
    <div class="text-xs space-y-1">
      <div class="opacity-60">
        Download this replica's graph as JSON Lines
        <span :if={@summary.graph[:nodes]}>
          ({@summary.graph[:nodes]} nodes, {@summary.graph[:edges]} edges)
        </span>
        — Glider's export, with every mesh stamp; import it with
        <code class="font-mono">Jido.Context.import/2</code>
        or <code class="font-mono">glider … import</code>.
      </div>
      <div class="flex flex-wrap gap-1">
        <a
          :for={{scope, %{label: label}} <- @scopes}
          href={"/export/#{scope}"}
          download
          class="btn btn-xs btn-outline"
          title={"Download #{label} as .jsonl"}
        >
          ⤓ {label}
        </a>
      </div>
    </div>
    """
  end

  @doc "The last deltas, newest first: who wrote what, and how long it took to get here."
  attr :mesh, :map, required: true
  attr :limit, :integer, default: 12

  def delta_ticker(assigns) do
    ~H"""
    <div class="space-y-1">
      <div class="text-xs opacity-60">On the wire</div>
      <div :if={@mesh.recent == []} class="text-xs opacity-60">Nothing yet.</div>
      <div
        :for={e <- Enum.take(@mesh.recent, @limit)}
        class="text-xs flex items-baseline gap-2 font-mono"
        title={"#{e.topic} · seq #{e.seq} · #{e.ops} op#{if e.ops == 1, do: "", else: "s"}"}
      >
        <span
          class="inline-block w-2 h-2 rounded-full shrink-0"
          style={"background: #{color(@mesh, e.origin)}"}
        ></span>
        <span class="shrink-0" style={"color: #{color(@mesh, e.origin)}"}>{e.origin}</span>
        <span class="truncate flex-1">{e.summary}</span>
        <span
          :if={lost(e) > 0}
          class="badge badge-xs badge-error badge-outline shrink-0"
          title="Lost to a write with a higher stamp; every replica kept the other one"
        >
          {lost(e)} lost
        </span>
        <span class="shrink-0 opacity-60">
          {if e.local, do: "here", else: "#{e.lag_ms}ms"}
        </span>
      </div>
    </div>
    """
  end

  @kinds ~w(goal task claim agent insight question decision note artifact message)
  @windows [
    {"all time", ""},
    {"last hour", "3600000"},
    {"last 10 min", "600000"},
    {"last minute", "60000"}
  ]

  @doc "What to draw: kinds, origins, how far back, and room to see it."
  attr :filters, :map, required: true
  attr :mesh, :map, required: true
  attr :expanded?, :boolean, default: false

  def canvas_toolbar(assigns) do
    assigns = assign(assigns, kinds: @kinds, windows: @windows)

    ~H"""
    <form
      id="hive-filters"
      phx-change="hive_filter"
      class="flex flex-wrap items-center gap-x-2 gap-y-1 text-xs"
    >
      <label
        :for={kind <- @kinds}
        class="flex items-center gap-1 cursor-pointer"
        title={"show #{kind}s"}
      >
        <input
          type="checkbox"
          name="kinds[]"
          value={kind}
          checked={@filters.kinds == [] or kind in @filters.kinds}
          class="checkbox checkbox-xs"
        />
        {kind}
      </label>
      <select name="origin" class="select select-bordered select-xs">
        <option value="">every pod</option>
        <option :for={o <- @mesh.origins} value={o.origin} selected={o.origin in @filters.origins}>
          {o.origin}
        </option>
      </select>
      <select name="window" class="select select-bordered select-xs">
        <option
          :for={{label, value} <- @windows}
          value={value}
          selected={to_string(@filters.window_ms || "") == value}
        >
          {label}
        </option>
      </select>
      <label class="flex items-center gap-1 cursor-pointer" title="Only what other pods wrote">
        <input
          type="checkbox"
          name="remote_only"
          checked={@filters.remote_only}
          class="checkbox checkbox-xs"
        /> not written here
      </label>
      <span class="flex-1"></span>
      <button
        type="button"
        class="btn btn-xs btn-ghost"
        phx-click={JS.dispatch("hive:fit", to: "#hive-mind")}
      >
        fit
      </button>
      <button type="button" class="btn btn-xs btn-ghost" phx-click="hive_toggle_expand">
        {if @expanded?, do: "close", else: "expand"}
      </button>
    </form>
    """
  end

  @doc "One entity, in full: what it is, who wrote it and when, and what it touches."
  attr :selected, :map, required: true
  attr :mesh, :map, required: true

  def node_drawer(assigns) do
    ~H"""
    <div id="hive-drawer" class="rounded-box border border-base-300 p-2 space-y-1 text-xs">
      <div class="flex items-baseline gap-2">
        <span class="badge badge-xs badge-outline">{@selected.node.kind}</span>
        <span class="font-semibold truncate flex-1">{@selected.node.caption}</span>
        <button
          class="btn btn-ghost btn-xs"
          phx-click="hive_expand_node"
          phx-value-key={@selected.node.key}
        >
          around
        </button>
        <button class="btn btn-ghost btn-xs" phx-click="hive_clear">close</button>
      </div>
      <div class="font-mono opacity-70">{@selected.node.key}</div>
      <div>
        <span class="opacity-60">written by</span>
        <span class="font-mono" style={"color: #{color(@mesh, @selected.stamp.origin)}"}>
          {@selected.stamp.origin}
        </span>
        <span class="opacity-60">· seq {@selected.stamp.seq} · {age(@selected.stamp.age_ms)} · {@selected.stamp.topic}</span>
      </div>
      <table :if={@selected.props != %{}} class="table table-xs">
        <tbody>
          <tr :for={{k, v} <- Enum.sort(@selected.props)}>
            <td class="opacity-60 w-24">{k}</td>
            <td class="break-words">{format_value(v)}</td>
          </tr>
        </tbody>
      </table>
      <div :if={@selected.neighbours != []} class="space-y-0.5">
        <div class="opacity-60">connected to</div>
        <button
          :for={n <- @selected.neighbours}
          class="flex items-center gap-1 w-full text-left hover:bg-base-200 rounded px-1"
          phx-click="hive_select"
          phx-value-key={n.key}
        >
          <span
            class="inline-block w-2 h-2 rounded-full shrink-0"
            style={"background: #{color(@mesh, n.origin)}"}
          ></span>
          <span class="font-mono opacity-60 shrink-0">{if n.dir == "out", do: "→", else: "←"} {n.type}</span>
          <span class="truncate">{n.caption}</span>
        </button>
      </div>
    </div>
    """
  end

  defp age(nil), do: ""
  defp age(ms) when ms < 60_000, do: "#{div(ms, 1000)}s ago"
  defp age(ms) when ms < 3_600_000, do: "#{div(ms, 60_000)}m ago"
  defp age(ms), do: "#{div(ms, 3_600_000)}h ago"

  defp format_value(v) when is_list(v), do: Enum.map_join(v, ", ", &to_string/1)
  defp format_value(v), do: to_string(v)

  defp color(mesh, origin), do: Map.get(mesh.colors, origin, "#64748b")

  defp lost(%{outcome: %{superseded: s, tombstoned: t}}), do: s + t
  defp lost(_), do: 0

  defp percent(share), do: "#{round(share * 100)}%"

  defp cell(seen, origin) when is_map(seen), do: Map.get(seen, origin, "—")
  defp cell(_, _), do: "?"

  defp origin_title(o) do
    [
      "#{o.deltas} deltas, #{o.ops} ops",
      "#{o.nodes} nodes, #{o.edges} edges",
      "highest seq #{o.last_seq}",
      o.age_ms && "last heard #{div(o.age_ms, 1000)}s ago",
      o.lag_p50_ms && "lag p50 #{o.lag_p50_ms}ms, max #{o.lag_max_ms}ms (pod clocks)",
      Map.get(o, :superseded, 0) > 0 && "#{o.superseded} writes lost to a higher stamp",
      Map.get(o, :tombstoned, 0) > 0 && "#{o.tombstoned} writes lost to a deletion",
      Map.get(o, :duplicates, 0) > 0 && "#{o.duplicates} duplicate deliveries dropped"
    ]
    |> Enum.reject(&(&1 in [nil, false]))
    |> Enum.join(" · ")
  end
end
