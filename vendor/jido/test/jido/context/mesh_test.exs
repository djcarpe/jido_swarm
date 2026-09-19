defmodule Jido.Context.MeshTest do
  use ExUnit.Case, async: false

  alias Jido.Context
  alias Jido.Context.Delta
  alias Jido.Context.Mesh

  defp unique(prefix), do: :"#{prefix}_#{System.unique_integer([:positive])}"

  defp start_mesh(opts) do
    name = Keyword.get_lazy(opts, :name, fn -> unique(:mesh) end)
    start_supervised!({Mesh, Keyword.put(opts, :name, name)}, id: name)
    name
  end

  defp start_graph(opts) do
    name = Keyword.get_lazy(opts, :name, fn -> unique(:g) end)
    start_supervised!({Jido.Context.Graph, Keyword.put(opts, :name, name)}, id: name)
    name
  end

  describe "subscriptions and routing" do
    test "a subscriber receives matching deltas" do
      mesh = start_mesh(transports: [])
      :ok = Mesh.subscribe(mesh, ["knowledge.**"])

      delta = Delta.new("knowledge.papers", "o", 1, [])
      :ok = Mesh.publish(mesh, delta)

      assert_receive {:jido_context_delta, ^mesh, ^delta}
    end

    test "a non-matching topic is not delivered" do
      mesh = start_mesh(transports: [])
      :ok = Mesh.subscribe(mesh, ["knowledge.**"])

      :ok = Mesh.publish(mesh, Delta.new("alerts", "o", 1, []))

      refute_receive {:jido_context_delta, _, _}, 100
    end

    test "* matches one segment only" do
      mesh = start_mesh(transports: [])
      :ok = Mesh.subscribe(mesh, ["knowledge.*"])

      :ok = Mesh.publish(mesh, Delta.new("knowledge.papers", "o", 1, []))
      assert_receive {:jido_context_delta, _, %Delta{topic: "knowledge.papers"}}

      :ok = Mesh.publish(mesh, Delta.new("knowledge.papers.nlp", "o", 2, []))
      refute_receive {:jido_context_delta, _, _}, 100
    end

    test "several patterns are matched as a union" do
      mesh = start_mesh(transports: [])
      :ok = Mesh.subscribe(mesh, ["alerts", "knowledge.*"])

      :ok = Mesh.publish(mesh, Delta.new("alerts", "o", 1, []))
      assert_receive {:jido_context_delta, _, %Delta{topic: "alerts"}}

      :ok = Mesh.publish(mesh, Delta.new("knowledge.x", "o", 2, []))
      assert_receive {:jido_context_delta, _, %Delta{topic: "knowledge.x"}}
    end

    test "unsubscribe stops delivery" do
      mesh = start_mesh(transports: [])
      :ok = Mesh.subscribe(mesh, ["**"])
      :ok = Mesh.unsubscribe(mesh)

      :ok = Mesh.publish(mesh, Delta.new("t", "o", 1, []))
      refute_receive {:jido_context_delta, _, _}, 100
    end

    test "a dead subscriber is dropped" do
      mesh = start_mesh(transports: [])
      parent = self()

      {:ok, pid} =
        Task.start(fn ->
          Mesh.subscribe(mesh, ["**"])
          send(parent, :subscribed)
          receive do: (:stop -> :ok)
        end)

      assert_receive :subscribed
      ref = Process.monitor(pid)
      send(pid, :stop)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}

      # The router must survive publishing to a subscriber that is gone.
      :ok = Mesh.publish(mesh, Delta.new("t", "o", 1, []))
      assert :ok = Mesh.sync(mesh)
      assert Mesh.alive?(mesh)
    end

    test "a duplicate delta id is delivered only once" do
      mesh = start_mesh(transports: [])
      :ok = Mesh.subscribe(mesh, ["**"])

      delta = Delta.new("t", "o", 1, [])
      :ok = Mesh.publish(mesh, delta)
      :ok = Mesh.deliver(mesh, delta)

      assert_receive {:jido_context_delta, _, ^delta}
      refute_receive {:jido_context_delta, _, ^delta}, 100
    end

    test "alive?/1 reflects whether a mesh is running" do
      mesh = start_mesh(transports: [])
      assert Mesh.alive?(mesh)
      refute Mesh.alive?(:no_such_mesh)
    end
  end

  describe "the :pg transport" do
    test "three graphs on one mesh converge" do
      mesh = start_mesh(transports: [:pg])

      graphs =
        for _ <- 1..3 do
          start_graph(mesh: mesh, topics: ["knowledge.**"], location: :memory)
        end

      [first | _] = graphs

      {:ok, _} =
        Context.assert(first, "paper:1", ["Paper"], %{title: "Shared"}, topic: "knowledge.papers")

      :ok = Mesh.sync(mesh)
      Enum.each(graphs, &Context.sync/1)

      for g <- graphs do
        assert {:ok, %{rows: [["Shared"]]}} =
                 Context.query(g, "MATCH (p:Paper) RETURN p.title")
      end
    end

    test "a graph only receives the topics it subscribed to" do
      mesh = start_mesh(transports: [:pg])

      listener = start_graph(mesh: mesh, topics: ["knowledge.**"], location: :memory)
      writer = start_graph(mesh: mesh, topics: ["knowledge.**"], location: :memory)

      {:ok, _} = Context.assert(writer, "a", ["Wanted"], %{}, topic: "knowledge.x")
      {:ok, _} = Context.assert(writer, "b", ["Unwanted"], %{}, topic: "other.y")

      :ok = Mesh.sync(mesh)
      Context.sync(listener)

      assert {:ok, %{rows: [_]}} = Context.query(listener, "MATCH (n:Wanted) RETURN n")
      assert {:ok, %{rows: []}} = Context.query(listener, "MATCH (n:Unwanted) RETURN n")
    end

    test "edges propagate along with their endpoints" do
      mesh = start_mesh(transports: [:pg])
      a = start_graph(mesh: mesh, location: :memory)
      b = start_graph(mesh: mesh, location: :memory)

      {:ok, _} = Context.assert(a, "p1", ["Paper"], %{title: "One"})
      {:ok, _} = Context.assert(a, "p2", ["Paper"], %{title: "Two"})
      {:ok, _} = Context.relate(a, "p1", "CITES", "p2", %{})

      :ok = Mesh.sync(mesh)
      Context.sync(b)

      assert {:ok, %{rows: [["One", "Two"]]}} =
               Context.query(b, "MATCH (x:Paper)-[:CITES]->(y:Paper) RETURN x.title, y.title")
    end

    test "a retraction propagates" do
      mesh = start_mesh(transports: [:pg])
      a = start_graph(mesh: mesh, location: :memory)
      b = start_graph(mesh: mesh, location: :memory)

      {:ok, _} = Context.assert(a, "p1", ["Paper"], %{})
      :ok = Mesh.sync(mesh)
      Context.sync(b)
      assert {:ok, %{rows: [_]}} = Context.query(b, "MATCH (p:Paper) RETURN p")

      {:ok, _} = Context.retract(a, "p1")
      :ok = Mesh.sync(mesh)
      Context.sync(b)

      assert {:ok, %{rows: []}} = Context.query(b, "MATCH (p:Paper) RETURN p")
    end

    test "concurrent writes to one key converge on the same value everywhere" do
      mesh = start_mesh(transports: [:pg])
      a = start_graph(mesh: mesh, location: :memory, origin: "aaa")
      b = start_graph(mesh: mesh, location: :memory, origin: "zzz")

      {:ok, _} = Context.assert(a, "k", ["T"], %{v: "from_a"})
      {:ok, _} = Context.assert(b, "k", ["T"], %{v: "from_b"})

      :ok = Mesh.sync(mesh)
      Context.sync(a)
      Context.sync(b)
      :ok = Mesh.sync(mesh)
      Context.sync(a)
      Context.sync(b)

      {:ok, %{rows: rows_a}} = Context.query(a, "MATCH (t:T) RETURN t.v")
      {:ok, %{rows: rows_b}} = Context.query(b, "MATCH (t:T) RETURN t.v")

      assert rows_a == rows_b
    end
  end

  describe "the log transport" do
    setup do
      Jido.Context.Store.Memory.reset()
      :ok
    end

    defp poller(mesh) do
      mesh
      |> Mesh.supervisor_name()
      |> Supervisor.which_children()
      |> Enum.find_value(fn
        {{Jido.Context.Mesh.Log, _}, pid, _, _} -> pid
        _ -> nil
      end)
    end

    test "publishing writes one immutable object per delta, plus a member marker" do
      mesh = start_mesh(transports: [{:log, store: :memory, interval: 60_000}])
      g = start_graph(mesh: mesh, location: :memory, origin: "scout")

      {:ok, delta} = Context.assert(g, "a", ["T"], %{}, topic: "knowledge.x")
      :ok = Mesh.sync(mesh)

      {:ok, keys} = Jido.Context.Store.Memory.list("", [])

      assert "topics/knowledge.x/scout/#{String.pad_leading(Integer.to_string(delta.seq), 20, "0")}.json" in keys

      assert "members/knowledge.x/scout" in keys
    end

    test "three agents that share only a store converge" do
      # No :pg at all. Each agent has its own mesh and its own graph, and the
      # only thing they have in common is the object store — which is exactly
      # the shape of three agents on three machines sharing an S3 bucket.
      store = :memory

      agents =
        for label <- ["alpha", "bravo", "charlie"] do
          mesh = start_mesh(transports: [{:log, store: store, interval: 60_000, catch_up: :all}])

          graph =
            start_graph(mesh: mesh, location: :memory, origin: label, topics: ["knowledge.**"])

          {label, mesh, graph}
        end

      [{_, _, alpha_graph} | _] = agents

      {:ok, _} =
        Context.assert(alpha_graph, "paper:1", ["Paper"], %{title: "Written by alpha"},
          topic: "knowledge.papers"
        )

      for {_, mesh, _} <- agents, do: Mesh.sync(mesh)

      # One poll pass on every agent pulls what the others wrote.
      for {_, mesh, graph} <- agents do
        :ok = Jido.Context.Mesh.Log.poll_now(poller(mesh))
        Context.sync(graph)
      end

      for {label, _, graph} <- agents do
        assert {:ok, %{rows: [["Written by alpha"]]}} =
                 Context.query(graph, "MATCH (p:Paper) RETURN p.title"),
               "#{label} did not converge"
      end
    end

    test "an agent that starts later catches up on the whole log" do
      store = :memory

      early_mesh =
        start_mesh(transports: [{:log, store: store, interval: 60_000, catch_up: :all}])

      early = start_graph(mesh: early_mesh, location: :memory, origin: "early")

      {:ok, _} = Context.assert(early, "a", ["Paper"], %{title: "Historic"}, topic: "knowledge.p")
      :ok = Mesh.sync(early_mesh)

      # Starts with nothing, and inherits the mesh's history.
      late_mesh = start_mesh(transports: [{:log, store: store, interval: 60_000, catch_up: :all}])
      late = start_graph(mesh: late_mesh, location: :memory, origin: "late")

      :ok = Jido.Context.Mesh.Log.poll_now(poller(late_mesh))
      Context.sync(late)

      assert {:ok, %{rows: [["Historic"]]}} =
               Context.query(late, "MATCH (p:Paper) RETURN p.title")
    end

    test "catch_up: :new skips the history that was already there" do
      store = :memory

      early_mesh =
        start_mesh(transports: [{:log, store: store, interval: 60_000, catch_up: :all}])

      early = start_graph(mesh: early_mesh, location: :memory, origin: "early2")

      {:ok, _} = Context.assert(early, "a", ["Paper"], %{title: "Before"}, topic: "knowledge.p")
      :ok = Mesh.sync(early_mesh)

      late_mesh = start_mesh(transports: [{:log, store: store, interval: 60_000, catch_up: :new}])
      late = start_graph(mesh: late_mesh, location: :memory, origin: "late2")

      :ok = Jido.Context.Mesh.Log.poll_now(poller(late_mesh))
      Context.sync(late)

      assert {:ok, %{rows: []}} = Context.query(late, "MATCH (p:Paper) RETURN p.title")

      # But anything written from now on does arrive.
      {:ok, _} = Context.assert(early, "b", ["Paper"], %{title: "After"}, topic: "knowledge.p")
      :ok = Mesh.sync(early_mesh)
      :ok = Jido.Context.Mesh.Log.poll_now(poller(late_mesh))
      Context.sync(late)

      assert {:ok, %{rows: [["After"]]}} = Context.query(late, "MATCH (p:Paper) RETURN p.title")
    end

    test "a poller only pulls the topics its mesh subscribes to" do
      store = :memory

      writer_mesh =
        start_mesh(transports: [{:log, store: store, interval: 60_000, catch_up: :all}])

      writer = start_graph(mesh: writer_mesh, location: :memory, origin: "writer")

      reader_mesh =
        start_mesh(
          transports: [{:log, store: store, interval: 60_000, catch_up: :all}],
          topics: ["knowledge.**"]
        )

      reader = start_graph(mesh: reader_mesh, location: :memory, origin: "reader", topics: ["**"])

      {:ok, _} = Context.assert(writer, "a", ["Wanted"], %{}, topic: "knowledge.x")
      {:ok, _} = Context.assert(writer, "b", ["Unwanted"], %{}, topic: "chatter")
      :ok = Mesh.sync(writer_mesh)

      :ok = Jido.Context.Mesh.Log.poll_now(poller(reader_mesh))
      Context.sync(reader)

      assert {:ok, %{rows: [_]}} = Context.query(reader, "MATCH (n:Wanted) RETURN n")
      assert {:ok, %{rows: []}} = Context.query(reader, "MATCH (n:Unwanted) RETURN n")
    end

    test "polling twice does not apply the same delta twice" do
      store = :memory

      writer_mesh =
        start_mesh(transports: [{:log, store: store, interval: 60_000, catch_up: :all}])

      writer = start_graph(mesh: writer_mesh, location: :memory, origin: "w2")

      reader_mesh =
        start_mesh(transports: [{:log, store: store, interval: 60_000, catch_up: :all}])

      reader = start_graph(mesh: reader_mesh, location: :memory, origin: "r2")

      {:ok, _} = Context.assert(writer, "a", ["T"], %{v: 1}, topic: "knowledge.p")
      :ok = Mesh.sync(writer_mesh)

      for _ <- 1..3 do
        :ok = Jido.Context.Mesh.Log.poll_now(poller(reader_mesh))
      end

      Context.sync(reader)

      assert {:ok, %{rows: [[1]]}} = Context.query(reader, "MATCH (t:T) RETURN t.v")
    end

    test ":retain trims older deltas and keeps the newest" do
      mesh = start_mesh(transports: [{:log, store: :memory, interval: 60_000, retain: 2}])
      g = start_graph(mesh: mesh, location: :memory, origin: "trim")

      for i <- 1..5 do
        {:ok, _} = Context.assert(g, "k#{i}", [], %{}, topic: "knowledge.t")
      end

      :ok = Mesh.sync(mesh)

      {:ok, keys} = Jido.Context.Store.Memory.list("topics/knowledge.t/trim/", [])
      assert length(keys) == 2
    end
  end

  describe "transports together" do
    test "pg and the log both carry a delta, and it is applied once" do
      Jido.Context.Store.Memory.reset()

      mesh =
        start_mesh(transports: [:pg, {:log, store: :memory, interval: 60_000, catch_up: :all}])

      g = start_graph(mesh: mesh, location: :memory, origin: "both")

      {:ok, _} = Context.assert(g, "a", ["T"], %{v: 1}, topic: "knowledge.t")
      :ok = Mesh.sync(mesh)

      # The poller reads back the object the mesh itself wrote.
      :ok = Jido.Context.Mesh.Log.poll_now(poller(mesh))
      Context.sync(g)

      assert {:ok, %{rows: [[1]]}} = Context.query(g, "MATCH (t:T) RETURN t.v")
    end
  end
end
