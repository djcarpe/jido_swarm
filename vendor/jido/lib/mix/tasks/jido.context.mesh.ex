defmodule Mix.Tasks.Jido.Context.Mesh do
  @shortdoc "Runs three Jido agents sharing one context and knowledge mesh"

  @moduledoc """
  Starts three Jido agents on a shared `Jido.Context` mesh and shows what each
  one ends up able to see.

      $ mix jido.context.mesh
      $ mix jido.context.mesh --transport log --store disk
      $ mix jido.context.mesh --location disk --store disk

  Everything below goes through the agent runtime — signals in, actions run —
  so this is also a worked example of `Jido.Context.Plugin`.

  The three agents are deliberately asymmetric, because that is the point of a
  mesh: each writes a different part of one graph, and each ends up able to
  traverse the whole of it.

  | Agent | Writes | Subscribes to |
  |---|---|---|
  | `scout` | papers it discovers | `knowledge.**` |
  | `librarian` | citations between them | `knowledge.**` |
  | `analyst` | findings, and task context | `**` |

  ## Options

  * `--transport pg` *(default)* — the agents share a BEAM cluster, and a delta
    reaches its peers in one message send.
  * `--transport log` — the agents share *only* an object store. Nothing passes
    between them directly: each writes immutable objects and polls for what the
    others wrote. This is the shape of three agents on three machines sharing
    an S3 bucket, exercised locally.
  * `--store memory` *(default)* / `--store disk` — where the topic log and the
    snapshots live.
  * `--path DIR` — base directory for `--store disk` and `--location disk`.
    Default `tmp/jido_mesh`.
  * `--location memory` *(default)* / `--location disk` — where each agent's own
    graph lives. `disk` gives each agent a `.gldb` file that survives a restart;
    run twice with `--location disk` and the second run starts already knowing.

  ## Pointing it at S3

  The demo offers memory and disk so it runs with no credentials. An S3-backed
  mesh is the same configuration with a different store:

      transports: [
        :pg,
        {:log, store: {:s3, bucket: "agent-graphs", prefix: "research"}}
      ]

  See `Jido.Context` for the full set of options.
  """

  use Mix.Task

  alias Jido.Context
  alias Jido.Context.Mesh
  alias Jido.Signal

  @mesh :demo_mesh

  defmodule Scout do
    @moduledoc "Finds papers and puts them on the mesh."
    use Jido.Agent,
      name: "demo_scout",
      plugins: [
        {Jido.Context.Plugin,
         %{graph: :demo_scout_graph, mesh: :demo_mesh, topics: ["knowledge.**"]}}
      ]
  end

  defmodule Librarian do
    @moduledoc "Relates papers the scout found."
    use Jido.Agent,
      name: "demo_librarian",
      plugins: [
        {Jido.Context.Plugin,
         %{graph: :demo_librarian_graph, mesh: :demo_mesh, topics: ["knowledge.**"]}}
      ]
  end

  defmodule Analyst do
    @moduledoc "Reads the whole mesh and records what it concluded."
    use Jido.Agent,
      name: "demo_analyst",
      plugins: [
        {Jido.Context.Plugin, %{graph: :demo_analyst_graph, mesh: :demo_mesh, topics: ["**"]}}
      ]
  end

  @agents [
    {:scout, Scout, :demo_scout_graph},
    {:librarian, Librarian, :demo_librarian_graph},
    {:analyst, Analyst, :demo_analyst_graph}
  ]

  @impl Mix.Task
  def run(argv) do
    {opts, _, _} =
      OptionParser.parse(argv,
        strict: [transport: :string, store: :string, path: :string, location: :string]
      )

    Mix.Task.run("app.start")

    unless Context.available?() do
      Mix.raise("""
      The Glider engine is not available.

      #{Jido.Context.Engine.Glider.install_hint()}
      """)
    end

    config = build_config(opts)

    say("Three agents, one mesh — #{config.transport_label}.")
    say("Graphs are #{config.location_kind}; snapshots and the log are #{config.store_kind}.")

    {:ok, _} = Jido.start_link(name: :demo_jido)
    {:ok, _} = Mesh.start_link(name: @mesh, transports: config.transports)

    servers = start_agents(config)

    tell_a_story(config, servers)
    report()

    say("Each agent above holds its own full replica. Nothing was queried remotely.")
  end

  # ===========================================================================
  # Configuration
  # ===========================================================================

  defp build_config(opts) do
    path = Keyword.get(opts, :path, "tmp/jido_mesh")
    store_kind = Keyword.get(opts, :store, "memory")
    location_kind = Keyword.get(opts, :location, "memory")
    transport_kind = Keyword.get(opts, :transport, "pg")

    store =
      case store_kind do
        "memory" -> :memory
        "disk" -> {:disk, path: Path.join(path, "store")}
        other -> Mix.raise("unknown --store #{inspect(other)}; expected memory or disk")
      end

    unless location_kind in ["memory", "disk"] do
      Mix.raise("unknown --location #{inspect(location_kind)}; expected memory or disk")
    end

    {transports, poll?} =
      case transport_kind do
        "pg" -> {[:pg], false}
        "log" -> {[{:log, store: store, interval: 250, catch_up: :all}], true}
        other -> Mix.raise("unknown --transport #{inspect(other)}; expected pg or log")
      end

    %{
      store: store,
      store_kind: store_kind,
      location_kind: location_kind,
      path: path,
      transports: transports,
      poll?: poll?,
      transport_label: transport_label(transport_kind, store_kind)
    }
  end

  defp transport_label("pg", _), do: "delta propagation over :pg"
  defp transport_label("log", store), do: "a topic log over #{store}, no direct connectivity"

  defp location(%{location_kind: "memory"}, _name), do: :memory

  defp location(%{location_kind: "disk", path: path}, name),
    do: {:disk, path: Path.join([path, "graphs", "#{name}.gldb"])}

  # ===========================================================================
  # Agents
  # ===========================================================================

  # Plugin config is compile-time, so `--location` and `--store` are applied
  # through `Jido.Context.Plugin.application_defaults/0` — which is exactly how
  # an application would configure these per environment.
  defp start_agents(config) do
    for {name, module, graph} <- @agents do
      # Each agent's graph gets its own file under `--location disk`, so the
      # default is set immediately before that agent starts.
      Application.put_env(:jido, Jido.Context,
        location: location(config, name),
        store: config.store,
        origin: Atom.to_string(name)
      )

      {:ok, pid} =
        Jido.AgentServer.start_link(agent: module, id: Atom.to_string(name), jido: :demo_jido)

      wait_until(fn -> is_pid(Process.whereis(Context.Graph.process_name(graph))) end)

      {name, pid, graph}
    end
  end

  # Plugin children start from the agent's `:post_init` continuation, so they
  # are up a moment after `start_link/1` returns.
  defp wait_until(fun, attempts \\ 100) do
    cond do
      fun.() ->
        :ok

      attempts == 0 ->
        Mix.raise("timed out waiting for the agents' graphs to start")

      true ->
        Process.sleep(20)
        wait_until(fun, attempts - 1)
    end
  end

  # ===========================================================================
  # The story
  # ===========================================================================

  defp tell_a_story(config, servers) do
    scout = server(servers, :scout)
    librarian = server(servers, :librarian)
    analyst = server(servers, :analyst)

    say("scout finds two papers")

    signal_agent(scout, "context.assert", %{
      key: "paper:attention",
      labels: ["Paper"],
      props: %{"title" => "Attention Is All You Need", "year" => 2017},
      topic: "knowledge.papers"
    })

    signal_agent(scout, "context.assert", %{
      key: "paper:seq2seq",
      labels: ["Paper"],
      props: %{"title" => "Sequence to Sequence Learning", "year" => 2014},
      topic: "knowledge.papers"
    })

    settle(config)

    say("librarian relates them — using nodes it never wrote")

    signal_agent(librarian, "context.relate", %{
      from: "paper:attention",
      type: "CITES",
      to: "paper:seq2seq",
      props: %{"section" => "related work"},
      topic: "knowledge.papers"
    })

    settle(config)

    say("analyst traverses the whole graph and records what it concluded")

    {:ok, agent} =
      signal_agent(analyst, "context.query", %{
        cypher: "MATCH (a:Paper)-[:CITES]->(b:Paper) RETURN a.title, b.title"
      })

    found = agent.state |> Map.get(:rows, []) |> length()

    signal_agent(analyst, "context.remember", %{
      scope: "task:survey",
      name: "citations_found",
      value: found,
      topic: "knowledge.tasks"
    })

    settle(config)
  end

  defp server(servers, name) do
    Enum.find_value(servers, fn {n, pid, _} -> if n == name, do: pid end)
  end

  defp signal_agent(pid, type, data) do
    Jido.AgentServer.call(pid, Signal.new!(type, data, source: "/mix/jido.context.mesh"))
  end

  # With `:pg` a sync is enough. With the log transport the deltas are objects
  # in a store, so each agent has to poll before it has seen them.
  defp settle(config) do
    :ok = Mesh.sync(@mesh)
    if config.poll?, do: poll_all()

    for {_, _, graph} <- @agents, do: Context.sync(graph)
    :ok = Mesh.sync(@mesh)
    for {_, _, graph} <- @agents, do: Context.sync(graph)
    :ok
  end

  defp poll_all do
    @mesh
    |> Mesh.supervisor_name()
    |> Supervisor.which_children()
    |> Enum.each(fn
      {{Mesh.Log, _}, pid, _, _} when is_pid(pid) -> Mesh.Log.poll_now(pid)
      _ -> :ok
    end)
  end

  # ===========================================================================
  # Report
  # ===========================================================================

  defp report do
    IO.puts("")

    for {name, _pid, graph} <- @agents do
      {:ok, %{rows: papers}} =
        Context.query(graph, "MATCH (p:Paper) RETURN p.title, p.year ORDER BY p.year")

      {:ok, %{rows: cites}} =
        Context.query(graph, "MATCH (a:Paper)-[:CITES]->(b:Paper) RETURN a.title, b.title")

      {:ok, recalled} = Context.recall(graph, "task:survey")
      {:ok, stats} = Context.stats(graph)

      IO.puts(IO.ANSI.bright() <> to_string(name) <> IO.ANSI.reset())
      IO.puts("  papers      #{format_papers(papers)}")
      IO.puts("  citations   #{format_cites(cites)}")
      IO.puts("  task:survey #{inspect(recalled)}")
      IO.puts("  graph       #{stats["nodes"]} nodes, #{stats["edges"]} edges")
      IO.puts("")
    end
  end

  defp format_papers([]), do: "(none)"

  defp format_papers(rows),
    do: Enum.map_join(rows, "; ", fn [title, year] -> "#{title} (#{year})" end)

  defp format_cites([]), do: "(none)"
  defp format_cites(rows), do: Enum.map_join(rows, "; ", fn [a, b] -> "#{a} -> #{b}" end)

  defp say(message), do: IO.puts(IO.ANSI.faint() <> "  " <> message <> IO.ANSI.reset())
end
