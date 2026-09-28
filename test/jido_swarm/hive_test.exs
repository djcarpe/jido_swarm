defmodule JidoSwarm.HiveTest do
  use ExUnit.Case, async: false

  alias JidoSwarm.Hive
  alias JidoSwarm.Hive.Board
  alias JidoSwarm.Hive.Claims
  alias JidoSwarm.Hive.Memory

  setup do
    name = :"hive_#{System.unique_integer([:positive])}"
    start_supervised!({Jido.Context.Graph, name: name, location: :memory})
    Application.put_env(:jido_swarm, :hive_graph, name)
    Application.put_env(:jido_swarm, :hive_settle_ms, 0)

    on_exit(fn ->
      Application.delete_env(:jido_swarm, :hive_graph)
      Application.delete_env(:jido_swarm, :hive_settle_ms)
    end)

    {:ok, a} = Hive.join(name: "alice", kind: "worker", skills: ["Elixir", "design"])
    {:ok, b} = Hive.join(name: "bob", kind: "mcp", skills: ["rust"])
    {:ok, a: a.id, b: b.id}
  end

  describe "membership" do
    test "join, heartbeat and leave are visible as presence", %{a: a, b: b} do
      assert Enum.map(Hive.agents(), & &1.id) |> Enum.sort() == Enum.sort([a, b])
      assert JidoSwarm.Hive.Agents.get(a).skills == ["elixir", "design"]

      :ok = Hive.leave(b)
      assert Enum.map(Hive.agents(), & &1.id) == [a]

      # Rejoining with the same id keeps the join time and skills.
      {:ok, again} = Hive.join(id: b, name: "bob")
      assert again.skills == ["rust"]
    end
  end

  describe "the board" do
    test "status is derived from dependencies, claims and subtasks", %{a: a} do
      {:ok, g} = Hive.add_goal(%{title: "Ship search", created_by: a})
      {:ok, t1} = Hive.add_task(%{title: "Design the index", goal: g, skills: ["design"]})

      {:ok, t2} =
        Hive.add_task(%{title: "Build the index", goal: g, depends_on: [t1], skills: ["rust"]})

      assert status(t1) == "open"
      assert status(t2) == "blocked"

      {:ok, _} = Hive.claim(t1, a)
      assert status(t1) == "claimed"

      :ok = Hive.finish(a, t1, "an inverted index over titles")
      assert status(t1) == "done"
      assert status(t2) == "open"

      [goal] = Hive.goals()
      assert goal.tasks == 2 and goal.done == 1
    end

    test "decomposition splits a task, and it is done when every piece is", %{a: a} do
      {:ok, big} = Hive.add_task(%{title: "Write the guide"})
      {:ok, _} = Hive.claim(big, a)

      {:ok, [s1, s2]} =
        Hive.decompose(big, [%{title: "Outline"}, %{title: "Draft", depends_on: [0]}], a)

      assert status(big) == "split"
      assert status(s1) == "open"
      assert status(s2) == "blocked", "the second piece waits on the first, by index"
      assert Hive.task(s1).goal == ""

      for s <- [s1, s2] do
        {:ok, _} = Hive.claim(s, a)
        :ok = Hive.finish(a, s, "ok")
      end

      assert status(big) == "done"
    end

    test "a dependency cycle reads as blocked instead of hanging" do
      {:ok, x} = Hive.add_task(%{title: "x"})
      {:ok, y} = Hive.add_task(%{title: "y", depends_on: [x]})
      :ok = Hive.depend(x, y)
      assert status(x) == "blocked" and status(y) == "blocked"
    end
  end

  describe "claims" do
    test "one winner among concurrent claimers", %{a: a, b: b} do
      {:ok, t} = Hive.add_task(%{title: "contested"})

      results =
        [a, b]
        |> Enum.map(fn who -> Task.async(fn -> {who, Hive.claim(t, who)} end) end)
        |> Enum.map(&Task.await/1)

      winners = for {who, {:ok, _}} <- results, do: who
      assert length(winners) == 1
      assert Claims.get(t).agent == hd(winners)
    end

    test "a claim held by another agent is refused; an expired lease is not", %{a: a, b: b} do
      {:ok, t} = Hive.add_task(%{title: "leased"})
      {:ok, _} = Hive.claim(t, a, lease_ms: 50)
      assert {:error, {:held_by, ^a}} = Hive.claim(t, b)

      Process.sleep(80)
      assert status(t) == "open", "the lease ran out, so the work is back on the board"
      assert {:ok, %{agent: ^b}} = Hive.claim(t, b)
    end

    test "only the holder can finish, and progress renews the lease", %{a: a, b: b} do
      {:ok, t} = Hive.add_task(%{title: "mine"})
      {:ok, c} = Hive.claim(t, a, lease_ms: 1_000)
      assert {:error, {:held_by, ^a}} = Hive.finish(b, t, "stolen")

      :ok = Hive.progress(a, t, "halfway")
      assert Claims.get(t).lease_until > c.lease_until
    end

    test "failures reopen a task until the attempt limit", %{a: a} do
      {:ok, t} = Hive.add_task(%{title: "flaky"})

      for n <- 1..Board.max_attempts() do
        {:ok, _} = Hive.claim(t, a)
        :ok = Hive.fail(a, t, "attempt #{n} failed")
      end

      assert status(t) == "failed"
      assert Memory.failures_of(a)[t] == Board.max_attempts()
    end

    test "a handoff releases the task and leaves a note for the next agent", %{a: a, b: b} do
      {:ok, t} = Hive.add_task(%{title: "relay"})
      {:ok, _} = Hive.claim(t, a)
      :ok = Hive.handoff(a, t, "parser works; tests for unicode still failing")

      assert status(t) == "open"
      {:ok, work} = Hive.claim(t, b) |> then(fn {:ok, _} -> Hive.context(t, agent: b) end)
      assert work.markdown =~ "unicode still failing"
    end
  end

  describe "scheduling" do
    test "agents take tasks matching their skills, highest priority first", %{a: a, b: b} do
      {:ok, _low} = Hive.add_task(%{title: "low elixir", skills: ["elixir"], priority: 1})
      {:ok, high} = Hive.add_task(%{title: "high elixir", skills: ["elixir"], priority: 5})
      {:ok, rust} = Hive.add_task(%{title: "rust work", skills: ["rust"], priority: 5})

      assert {:ok, %{task: %{key: ^high}, context: ctx}} = Hive.next_task(a)
      assert ctx =~ "# Task: high elixir"
      assert {:ok, %{task: %{key: ^rust}}} = Hive.next_task(b)
    end

    test "an agent avoids a task it failed while another is available", %{a: a} do
      {:ok, t1} = Hive.add_task(%{title: "one", priority: 3})
      {:ok, t2} = Hive.add_task(%{title: "two", priority: 3})
      {:ok, _} = Hive.claim(t1, a)
      :ok = Hive.fail(a, t1, "I could not")

      assert {:ok, %{task: %{key: ^t2}}} = Hive.next_task(a)
    end

    test "heat spreads agents out", %{a: a, b: b} do
      {:ok, t1} = Hive.add_task(%{title: "popular", priority: 3})
      {:ok, _t2} = Hive.add_task(%{title: "quiet", priority: 3})
      for who <- [a, b], _ <- 1..3, do: Memory.touch(who, t1)

      [first | _] = Hive.ranked(a)
      assert first.title == "quiet"
      assert first.why.heat == 0.0
    end

    test ":none when there is nothing to do", %{a: a} do
      assert Hive.next_task(a) == :none
    end
  end

  describe "shared memory" do
    test "relevant insights surface in the context pack, contradictions flagged", %{a: a, b: b} do
      {:ok, t} =
        Hive.add_task(%{title: "Speed up the parser", detail: "the tokenizer allocates too much"})

      {:ok, i1} =
        Hive.share(a, %{
          text: "The tokenizer allocates a binary per token",
          kind: "finding",
          about: [t],
          confidence: 0.9
        })

      {:ok, _} =
        Hive.share(b, %{
          text: "Allocation is not the parser bottleneck; IO is",
          kind: "hypothesis",
          contradicts: [i1]
        })

      {:ok, _} = Hive.share(b, %{text: "Unrelated note about deployment", kind: "fact"})
      :ok = Hive.endorse(b, i1)

      {:ok, pack} = Hive.context(t)
      assert pack.markdown =~ "binary per token"
      assert pack.markdown =~ "disputed by"
      refute pack.markdown =~ "deployment"

      [top | _] = Memory.relevant([t], "parser tokenizer")
      assert top.key == i1 and top.consensus == 1
    end

    test "questions route by skill and answers reach the asker's context", %{a: a, b: b} do
      {:ok, t} = Hive.add_task(%{title: "Pick a hash"})

      {:ok, q} =
        Hive.ask(a, %{text: "Is ahash safe for untrusted keys?", skills: ["rust"], about: [t]})

      assert [%{key: ^q}] = Hive.inbox(b).questions
      assert Hive.inbox(a).questions == [], "you are not asked your own question"

      {:ok, _} = Hive.answer(b, q, "Not for HashDoS-sensitive maps; use SipHash there.")
      {:ok, pack} = Hive.context(t)
      assert pack.markdown =~ "use SipHash there"
      assert Hive.inbox(b).questions == []
    end

    test "messages reach an agent directly, by skill, or broadcast", %{a: a, b: b} do
      {:ok, _} = Hive.message(a, b, "can you review task:x?")
      {:ok, _} = Hive.message(a, "skill:rust", "rust folks: unsafe audit needed")
      {:ok, _} = Hive.message(b, "*", "deploying at noon")

      texts = Hive.inbox(b).messages |> Enum.map(& &1.text) |> Enum.sort()
      assert texts == ["can you review task:x?", "rust folks: unsafe audit needed"]
      assert Enum.map(Hive.inbox(a).messages, & &1.text) == ["deploying at noon"]
    end

    test "finish records insights, artifacts and decisions against the task", %{a: a} do
      {:ok, t} = Hive.add_task(%{title: "Benchmark it"})
      {:ok, _} = Hive.claim(t, a)

      :ok =
        Hive.finish(a, t, "3x faster",
          insights: [%{text: "Batching writes gives 3x", confidence: 0.8}],
          artifacts: [%{uri: "bench/results.json", summary: "raw numbers"}],
          decisions: [%{text: "Batch by 1000", rationale: "knee of the curve"}]
        )

      assert [%{about: [^t]}] = Hive.insights()
      assert [%{uri: "bench/results.json"}] = Memory.artifacts([t])
      assert [%{text: "Batch by 1000"}] = Memory.decisions()
    end
  end

  describe "reading the board" do
    test "digest and search", %{a: a} do
      {:ok, g} = Hive.add_goal(%{title: "Faster imports"})
      {:ok, _} = Hive.add_task(%{title: "Profile the importer", goal: g})
      {:ok, _} = Hive.share(a, %{text: "Importer spends time in JSON decoding"})

      d = Hive.digest()
      assert [%{title: "Faster imports", tasks: 1}] = d.goals
      assert d.counts["open"] == 1
      assert length(d.agents) == 2

      kinds = Hive.search("importer profile") |> Enum.map(& &1.kind)
      assert "task" in kinds and "insight" in kinds
    end

    test "read_query answers reads and refuses writes" do
      {:ok, _} = Hive.add_task(%{title: "count me"})
      assert {:ok, %{rows: [[1]]}} = Hive.read_query("MATCH (t:HiveTask) RETURN count(t)")
      assert {:error, msg} = Hive.read_query("MATCH (t:HiveTask) DETACH DELETE t")
      assert msg =~ "read-only"
      assert {:error, _} = Hive.read_query(~S|CALL pagerank(write: "rank")|)
    end
  end

  defp status(key), do: Hive.task(key).status

  describe "explaining a pick" do
    test "the context pack names the entities each section came from", %{a: a, b: b} do
      {:ok, goal} = Hive.add_goal(%{title: "ship", created_by: a})
      {:ok, dep} = Hive.add_task(%{title: "design the index", goal: goal, created_by: a})

      {:ok, task} =
        Hive.add_task(%{
          title: "build the index",
          goal: goal,
          depends_on: [dep],
          skills: "rust",
          created_by: a
        })

      {:ok, insight} = Hive.share(b, %{text: "the index must be built in rust", about: [task]})
      {:ok, _claim} = JidoSwarm.Hive.Claims.claim(task, a)
      :ok = Hive.progress(a, task, "started on the index")

      {:ok, pack} = JidoSwarm.Hive.ContextPack.build(task)

      assert pack.sources.task == [task]
      assert pack.sources.why == [goal]
      assert pack.sources.inputs == [dep]
      assert [note] = pack.sources.handoffs
      assert String.starts_with?(note, "note:")
      assert insight in pack.sources.knowledge
      assert ("agent:" <> a) in pack.sources.around
      # Every key named is one the pack rendered.
      for {section, keys} <- pack.sources, key <- keys, section not in [:around] do
        assert pack.markdown =~ key or section in [:task, :why, :inputs, :handoffs]
      end
    end

    test "every active agent's score for a task is spelled out", %{a: a, b: b} do
      {:ok, task} = Hive.add_task(%{title: "port it", skills: "rust", priority: 4, created_by: a})

      {:ok, rows} = JidoSwarm.Hive.Scheduler.explain(task)
      by_agent = Map.new(rows, &{&1.agent, &1})

      # bob has rust; alice does not, and the task is too young to be an orphan.
      assert by_agent[b].eligible and by_agent[b].why.skill_fit == 1.0
      refute by_agent[a].eligible
      assert by_agent[b].score > by_agent[a].score
      assert by_agent[b].why.priority == 4
      assert hd(rows).agent == b

      assert JidoSwarm.Hive.Scheduler.explain("task:nope") == {:error, :no_such_task}
    end
  end
end
