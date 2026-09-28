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
        <span class="shrink-0 opacity-60">
          {if e.local, do: "here", else: "#{e.lag_ms}ms"}
        </span>
      </div>
    </div>
    """
  end

  defp color(mesh, origin), do: Map.get(mesh.colors, origin, "#64748b")

  defp percent(share), do: "#{round(share * 100)}%"

  defp cell(seen, origin) when is_map(seen), do: Map.get(seen, origin, "—")
  defp cell(_, _), do: "?"

  defp origin_title(o) do
    [
      "#{o.deltas} deltas, #{o.ops} ops",
      "#{o.nodes} nodes, #{o.edges} edges",
      "highest seq #{o.last_seq}",
      o.age_ms && "last heard #{div(o.age_ms, 1000)}s ago",
      o.lag_p50_ms && "lag p50 #{o.lag_p50_ms}ms, max #{o.lag_max_ms}ms (pod clocks)"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end
end
