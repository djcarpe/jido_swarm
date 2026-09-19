defmodule Jido.Context.GraphTest do
  use ExUnit.Case, async: true

  alias Jido.Context
  alias Jido.Context.Delta
  alias Jido.Context.Graph

  setup do
    unless Context.available?() do
      raise "the Glider engine is unavailable; these tests exercise the real engine"
    end

    :ok
  end

  defp start_graph(opts) do
    name = :"g_#{System.unique_integer([:positive])}"
    pid = start_supervised!({Graph, Keyword.merge([name: name, location: :memory], opts)})
    {name, pid}
  end

  defp rows(graph, cypher) do
    {:ok, %{rows: rows}} = Context.query(graph, cypher)
    rows
  end

  # A graph started with `start_link/1` is linked to the test process, so it is
  # already shutting down by the time `on_exit` runs. Stopping it is still worth
  # doing — it releases the file lock promptly — but it must tolerate losing the
  # race.
  defp stop_on_exit(pid) do
    ExUnit.Callbacks.on_exit(fn ->
      if Process.alive?(pid) do
        try do
          GenServer.stop(pid, :normal, 1_000)
        catch
          :exit, _ -> :ok
        end
      end
    end)
  end

  describe "asserting entities" do
    test "creates a node with labels and properties" do
      {g, _} = start_graph([])

      assert {:ok, %Delta{}} =
               Context.assert(g, "paper:1", ["Paper"], %{title: "A", year: 2017})

      assert [["A", 2017]] = rows(g, "MATCH (p:Paper) RETURN p.title, p.year")
    end

    test "carries the Ctx label and the replication stamp" do
      {g, _} = start_graph(origin: "scout")

      {:ok, delta} = Context.assert(g, "paper:1", ["Paper"], %{title: "A"})

      assert [[labels, key, seq, origin]] =
               rows(g, ~S|MATCH (p:Paper) RETURN labels(p), p._key, p._seq, p._origin|)

      assert "Ctx" in labels
      assert "Paper" in labels
      assert key == "paper:1"
      assert seq == delta.seq
      assert origin == "scout"
    end

    test "a second assert on the same key updates rather than duplicating" do
      {g, _} = start_graph([])

      {:ok, _} = Context.assert(g, "paper:1", ["Paper"], %{title: "A"})
      {:ok, _} = Context.assert(g, "paper:1", ["Paper"], %{title: "B"})

      assert [["B"]] = rows(g, "MATCH (p:Paper) RETURN p.title")
    end

    test "an update adds new labels without dropping the old ones" do
      {g, _} = start_graph([])

      {:ok, _} = Context.assert(g, "paper:1", ["Paper"], %{})
      {:ok, _} = Context.assert(g, "paper:1", ["Cited"], %{})

      assert [[labels]] = rows(g, ~S|MATCH (p {_key: "paper:1"}) RETURN labels(p)|)
      assert "Paper" in labels
      assert "Cited" in labels
    end

    test "the sequence advances with every local write" do
      {g, _} = start_graph([])

      {:ok, first} = Context.assert(g, "a", [], %{})
      {:ok, second} = Context.assert(g, "b", [], %{})

      assert second.seq > first.seq
    end

    test "a hostile label is rejected without touching the graph" do
      {g, _} = start_graph([])

      assert {:error, message} = Context.assert(g, "k", ["X {a:1}) DETACH DELETE n //"], %{})
      assert message =~ "invalid Cypher identifier"
      assert {:ok, %{"nodes" => 0}} = Context.stats(g)
    end

    test "a value that looks like an injection is stored as text" do
      {g, _} = start_graph([])

      hostile = ~S|"}) DETACH DELETE n CREATE (x:Pwned {a:"|
      {:ok, _} = Context.assert(g, "k", ["Thing"], %{note: hostile})

      assert [[^hostile]] = rows(g, "MATCH (t:Thing) RETURN t.note")
      assert [] = rows(g, "MATCH (p:Pwned) RETURN p")
    end

    test "a reserved property is rejected" do
      {g, _} = start_graph([])

      assert {:error, message} = Context.assert(g, "k", [], %{_seq: 99})
      assert message =~ "reserved"
    end
  end

  describe "relating entities" do
    test "creates an edge between two nodes" do
      {g, _} = start_graph([])

      {:ok, _} = Context.assert(g, "a", ["Paper"], %{title: "A"})
      {:ok, _} = Context.assert(g, "b", ["Paper"], %{title: "B"})
      {:ok, _} = Context.relate(g, "a", "CITES", "b", %{section: "intro"})

      assert [["A", "intro", "B"]] =
               rows(g, "MATCH (x)-[r:CITES]->(y) RETURN x.title, r.section, y.title")
    end

    test "an edge to an unknown node creates a placeholder, so order does not matter" do
      {g, _} = start_graph([])

      {:ok, _} = Context.relate(g, "a", "CITES", "b", %{})
      {:ok, _} = Context.assert(g, "b", ["Paper"], %{title: "B"})

      assert [["B"]] = rows(g, "MATCH (x)-[:CITES]->(y:Paper) RETURN y.title")
    end

    test "re-relating the same pair updates the edge rather than duplicating it" do
      {g, _} = start_graph([])

      {:ok, _} = Context.relate(g, "a", "CITES", "b", %{section: "one"})
      {:ok, _} = Context.relate(g, "a", "CITES", "b", %{section: "two"})

      assert [["two"]] = rows(g, "MATCH ()-[r:CITES]->() RETURN r.section")
    end

    test "unrelate deletes the edge and leaves the nodes" do
      {g, _} = start_graph([])

      {:ok, _} = Context.assert(g, "a", ["Paper"], %{})
      {:ok, _} = Context.assert(g, "b", ["Paper"], %{})
      {:ok, _} = Context.relate(g, "a", "CITES", "b", %{})
      {:ok, _} = Context.unrelate(g, "a", "CITES", "b")

      assert [] = rows(g, "MATCH ()-[r:CITES]->() RETURN r")
      assert length(rows(g, "MATCH (p:Paper) RETURN p")) == 2
    end
  end

  describe "retracting" do
    test "deletes the node and its edges" do
      {g, _} = start_graph([])

      {:ok, _} = Context.assert(g, "a", ["Paper"], %{})
      {:ok, _} = Context.assert(g, "b", ["Paper"], %{})
      {:ok, _} = Context.relate(g, "a", "CITES", "b", %{})
      {:ok, _} = Context.retract(g, "a")

      # The live node is gone; what remains is the `:CtxTomb` marker, which
      # carries no other label and so is invisible to a label-scoped query.
      assert [] = rows(g, ~S|MATCH (p:Ctx {_key: "a"}) RETURN p|)
      assert [] = rows(g, "MATCH ()-[r:CITES]->() RETURN r")
    end

    test "leaves a tombstone that a stale assert cannot beat" do
      {g, _} = start_graph(origin: "local")

      {:ok, _} = Context.assert(g, "a", ["Paper"], %{title: "A"})
      {:ok, retraction} = Context.retract(g, "a")

      # A delta stamped *earlier* than the retraction, arriving late.
      stale =
        Delta.new("context", "peer", retraction.seq - 1, [
          {:put_node, "a", ["Paper"], %{"title" => "Zombie"}}
        ])

      Graph.apply_delta(g, stale)
      Context.sync(g)

      assert [] = rows(g, "MATCH (p:Paper) RETURN p.title")
    end

    test "a genuinely newer assert does bring the entity back" do
      {g, _} = start_graph(origin: "local")

      {:ok, _} = Context.assert(g, "a", ["Paper"], %{title: "A"})
      {:ok, retraction} = Context.retract(g, "a")

      newer =
        Delta.new("context", "peer", retraction.seq + 5, [
          {:put_node, "a", ["Paper"], %{"title" => "Reborn"}}
        ])

      Graph.apply_delta(g, newer)
      Context.sync(g)

      assert [["Reborn"]] = rows(g, "MATCH (p:Paper) RETURN p.title")
    end

    test "tombstones do not appear in ordinary queries" do
      {g, _} = start_graph([])

      {:ok, _} = Context.assert(g, "a", ["Paper"], %{})
      {:ok, _} = Context.retract(g, "a")

      assert [] = rows(g, "MATCH (p:Paper) RETURN p")
      assert [] = rows(g, "MATCH (p:Ctx) RETURN p")
      assert length(rows(g, "MATCH (t:CtxTomb) RETURN t")) == 1
    end
  end

  describe "last-writer-wins" do
    test "a higher sequence wins" do
      {g, _} = start_graph(origin: "local")

      Graph.apply_delta(
        g,
        Delta.new("context", "peer", 5, [{:put_node, "a", [], %{"v" => "old"}}])
      )

      Graph.apply_delta(
        g,
        Delta.new("context", "peer", 9, [{:put_node, "a", [], %{"v" => "new"}}])
      )

      Context.sync(g)

      assert [["new"]] = rows(g, ~S|MATCH (n {_key: "a"}) RETURN n.v|)
    end

    test "a lower sequence arriving later is ignored" do
      {g, _} = start_graph(origin: "local")

      Graph.apply_delta(
        g,
        Delta.new("context", "peer", 9, [{:put_node, "a", [], %{"v" => "new"}}])
      )

      Graph.apply_delta(
        g,
        Delta.new("context", "peer", 5, [{:put_node, "a", [], %{"v" => "old"}}])
      )

      Context.sync(g)

      assert [["new"]] = rows(g, ~S|MATCH (n {_key: "a"}) RETURN n.v|)
    end

    test "equal sequences are broken by origin, the same way on every graph" do
      {g1, _} = start_graph(origin: "local1")
      {g2, _} = start_graph(origin: "local2")

      a = Delta.new("context", "aaa", 4, [{:put_node, "k", [], %{"v" => "from_a"}}])
      z = Delta.new("context", "zzz", 4, [{:put_node, "k", [], %{"v" => "from_z"}}])

      # Same deltas, opposite order.
      Graph.apply_delta(g1, a)
      Graph.apply_delta(g1, z)
      Graph.apply_delta(g2, z)
      Graph.apply_delta(g2, a)
      Context.sync(g1)
      Context.sync(g2)

      assert rows(g1, ~S|MATCH (n {_key: "k"}) RETURN n.v|) ==
               rows(g2, ~S|MATCH (n {_key: "k"}) RETURN n.v|)

      assert [["from_z"]] = rows(g1, ~S|MATCH (n {_key: "k"}) RETURN n.v|)
    end

    test "applying the same delta twice changes nothing" do
      {g, _} = start_graph(origin: "local")

      delta = Delta.new("context", "peer", 3, [{:put_node, "a", ["T"], %{"v" => 1}}])

      Graph.apply_delta(g, delta)
      Graph.apply_delta(g, delta)
      Context.sync(g)

      assert length(rows(g, "MATCH (t:T) RETURN t")) == 1
    end

    test "the local clock advances past what a peer has used" do
      {g, _} = start_graph(origin: "local")

      Graph.apply_delta(g, Delta.new("context", "peer", 50, [{:put_node, "a", [], %{}}]))
      Context.sync(g)

      {:ok, local} = Context.assert(g, "b", [], %{})
      assert local.seq > 50
    end

    test "a graph ignores a delta echoed back from its own origin" do
      {g, _} = start_graph(origin: "local")

      {:ok, _} = Context.assert(g, "a", ["T"], %{v: "mine"})

      echo = Delta.new("context", "local", 1, [{:put_node, "a", ["T"], %{"v" => "stale_echo"}}])
      Graph.apply_delta(g, echo)
      Context.sync(g)

      assert [["mine"]] = rows(g, "MATCH (t:T) RETURN t.v")
    end
  end

  describe "context scopes" do
    test "remember and recall round-trip" do
      {g, _} = start_graph([])

      {:ok, _} = Context.remember(g, "task:42", "budget", 3)
      {:ok, _} = Context.remember(g, "task:42", "owner", "scout")

      assert {:ok, %{"budget" => 3, "owner" => "scout"}} = Context.recall(g, "task:42")
    end

    test "rewriting an entry overwrites it" do
      {g, _} = start_graph([])

      {:ok, _} = Context.remember(g, "task:42", "budget", 3)
      {:ok, _} = Context.remember(g, "task:42", "budget", 1)

      assert {:ok, %{"budget" => 1}} = Context.recall(g, "task:42")
    end

    test "scopes are independent" do
      {g, _} = start_graph([])

      {:ok, _} = Context.remember(g, "task:1", "k", "one")
      {:ok, _} = Context.remember(g, "task:2", "k", "two")

      assert {:ok, %{"k" => "one"}} = Context.recall(g, "task:1")
      assert {:ok, %{"k" => "two"}} = Context.recall(g, "task:2")
    end

    test "recall of an unknown scope is an empty map" do
      {g, _} = start_graph([])
      assert {:ok, %{}} = Context.recall(g, "task:nothing")
    end

    test "structured values survive the round trip as data" do
      {g, _} = start_graph([])

      {:ok, _} = Context.remember(g, "s", "cfg", %{"a" => 1, "b" => [1, 2]})

      assert {:ok, %{"cfg" => %{"a" => 1, "b" => [1, 2]}}} = Context.recall(g, "s")
    end

    test "a flat list is stored as a native list" do
      {g, _} = start_graph([])

      {:ok, _} = Context.remember(g, "s", "tags", ["a", "b"])

      assert {:ok, %{"tags" => ["a", "b"]}} = Context.recall(g, "s")
    end

    test "forget removes one entry and leaves the rest" do
      {g, _} = start_graph([])

      {:ok, _} = Context.remember(g, "s", "a", 1)
      {:ok, _} = Context.remember(g, "s", "b", 2)
      {:ok, _} = Context.forget(g, "s", "a")

      assert {:ok, %{"b" => 2}} = Context.recall(g, "s")
    end
  end

  describe "fetch/2" do
    test "returns the node" do
      {g, _} = start_graph([])

      {:ok, _} = Context.assert(g, "a", ["Paper"], %{title: "A"})

      assert {:ok, node} = Context.fetch(g, "a")
      assert node.props["title"] == "A"
    end

    test "is :not_found for an unknown key" do
      {g, _} = start_graph([])
      assert :not_found = Context.fetch(g, "nope")
    end
  end

  describe "batched commits" do
    test "a node and its edge land together" do
      {g, _} = start_graph([])

      {:ok, _} =
        Context.commit(g, [
          {:put_node, "run:9", ["Run"], %{"status" => "ok"}},
          {:put_node, "task:42", ["Task"], %{}},
          {:put_edge, "run:9", "OF_TASK", "task:42", %{}}
        ])

      assert [["ok"]] = rows(g, "MATCH (r:Run)-[:OF_TASK]->(:Task) RETURN r.status")
    end

    test "one delta covers the whole batch" do
      {g, _} = start_graph([])

      {:ok, delta} =
        Context.commit(g, [
          {:put_node, "a", [], %{}},
          {:put_node, "b", [], %{}}
        ])

      assert length(delta.ops) == 2
    end
  end

  describe "persistence" do
    @tag :tmp_dir
    test "a disk-backed graph survives a restart", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "graph.gldb")
      name = :"disk_#{System.unique_integer([:positive])}"

      {:ok, pid} = Graph.start_link(name: name, location: {:disk, path: path})
      {:ok, _} = Context.assert(name, "paper:1", ["Paper"], %{title: "Durable"})
      :ok = GenServer.stop(pid)

      {:ok, pid2} = Graph.start_link(name: name, location: {:disk, path: path})
      stop_on_exit(pid2)

      assert [["Durable"]] = rows(name, "MATCH (p:Paper) RETURN p.title")
    end

    @tag :tmp_dir
    test "a graph restores from a snapshot in its store", %{tmp_dir: tmp_dir} do
      store = {:disk, path: Path.join(tmp_dir, "store")}
      name = :"snap_#{System.unique_integer([:positive])}"

      {:ok, pid} = Graph.start_link(name: name, location: :memory, store: store)
      {:ok, _} = Context.assert(name, "paper:1", ["Paper"], %{title: "Snapshotted"})
      :ok = Context.snapshot(name)
      :ok = GenServer.stop(pid)

      # A brand new in-memory graph, same store.
      {:ok, pid2} = Graph.start_link(name: name, location: :memory, store: store)
      stop_on_exit(pid2)

      assert [["Snapshotted"]] = rows(name, "MATCH (p:Paper) RETURN p.title")
    end

    @tag :tmp_dir
    test "the clock resumes above the restored stamps", %{tmp_dir: tmp_dir} do
      store = {:disk, path: Path.join(tmp_dir, "store")}
      name = :"clock_#{System.unique_integer([:positive])}"

      {:ok, pid} = Graph.start_link(name: name, location: :memory, store: store)
      for i <- 1..5, do: {:ok, _} = Context.assert(name, "k#{i}", [], %{})
      {:ok, last} = Context.assert(name, "final", [], %{})
      :ok = Context.snapshot(name)
      :ok = GenServer.stop(pid)

      {:ok, pid2} = Graph.start_link(name: name, location: :memory, store: store)
      stop_on_exit(pid2)

      {:ok, next} = Context.assert(name, "after_restore", [], %{})
      assert next.seq > last.seq
    end

    @tag :tmp_dir
    test "restore: false starts empty even with a snapshot present", %{tmp_dir: tmp_dir} do
      store = {:disk, path: Path.join(tmp_dir, "store")}
      name = :"norestore_#{System.unique_integer([:positive])}"

      {:ok, pid} = Graph.start_link(name: name, location: :memory, store: store)
      {:ok, _} = Context.assert(name, "a", ["Paper"], %{})
      :ok = Context.snapshot(name)
      :ok = GenServer.stop(pid)

      {:ok, pid2} =
        Graph.start_link(name: name, location: :memory, store: store, restore: false)

      stop_on_exit(pid2)

      assert [] = rows(name, "MATCH (p:Paper) RETURN p")
    end

    test "snapshot_every writes after the configured number of writes" do
      name = :"auto_#{System.unique_integer([:positive])}"
      key = "snapshots/#{name}.jsonl"
      Jido.Context.Store.Memory.delete(key, [])

      pid =
        start_supervised!(
          {Graph, name: name, location: :memory, store: :memory, snapshot_every: 2}
        )

      assert is_pid(pid)

      {:ok, _} = Context.assert(name, "a", [], %{})
      assert :not_found = Jido.Context.Store.Memory.get(key, [])

      {:ok, _} = Context.assert(name, "b", [], %{})
      assert {:ok, jsonl} = Jido.Context.Store.Memory.get(key, [])
      assert jsonl =~ "_key"
    end

    test "a graph without a store cannot snapshot" do
      {g, _} = start_graph([])
      assert {:error, :no_store} = Context.snapshot(g)
    end
  end

  describe "export/1" do
    test "dumps the graph as JSON Lines" do
      {g, _} = start_graph([])

      {:ok, _} = Context.assert(g, "a", ["Paper"], %{title: "A"})

      assert {:ok, jsonl} = Context.export(g)
      assert jsonl =~ ~S|"Paper"|
      assert jsonl =~ ~S|"title":"A"|
    end
  end
end
