defmodule JidoSwarm.GliderMetricsTest do
  use ExUnit.Case, async: false

  alias Jido.Context
  alias JidoSwarm.GliderMetrics

  setup do
    GliderMetrics.reset()

    name = :"metrics_#{System.unique_integer([:positive])}"
    pid = start_supervised!({Jido.Context.Graph, name: name, location: :memory})
    assert is_pid(pid)

    {:ok, graph: name}
  end

  defp op(snapshot, operation), do: Enum.find(snapshot.operations, &(&1.operation == operation))

  test "records real graph work, not just call counts", %{graph: graph} do
    for i <- 1..5 do
      {:ok, _} = Context.assert(graph, "thing:#{i}", ["Thing"], %{"v" => i})
    end

    {:ok, _} = Context.query(graph, "MATCH (t:Thing) RETURN t.v")

    snapshot = GliderMetrics.snapshot()

    # Writes are counted, and so is the work they did.
    run = op(snapshot, :run)
    assert run.calls >= 5
    assert run.touched > 0

    # Reads report rows returned, which is what says the graph is being used
    # rather than merely called.
    query = op(snapshot, :query)
    assert query.calls >= 1
    assert query.rows >= 5

    assert snapshot.totals.calls > 0
    assert snapshot.totals.busy_us > 0
  end

  test "latency percentiles are populated and ordered", %{graph: graph} do
    for i <- 1..40, do: {:ok, _} = Context.assert(graph, "p:#{i}", ["P"], %{"v" => i})

    run = op(GliderMetrics.snapshot(), :run)

    assert run.p50_us > 0
    assert run.p50_us <= run.p95_us
    assert run.p95_us <= run.p99_us
    assert run.p99_us <= run.max_us
  end

  test "a failing operation is counted as an error, not lost", %{graph: graph} do
    {:ok, _} = Context.query(graph, "MATCH (t:Thing) RETURN t")
    {:error, _} = Context.query(graph, "NOT VALID CYPHER AT ALL")

    snapshot = GliderMetrics.snapshot()
    query = op(snapshot, :query)

    assert query.calls >= 2
    assert query.errors >= 1
    assert query.error_rate > 0
    assert snapshot.totals.errors >= 1
  end

  test "groups by Cypher keyword so cheap reads and expensive calls separate", %{graph: graph} do
    {:ok, _} = Context.assert(graph, "k:1", ["K"], %{})
    {:ok, _} = Context.query(graph, "MATCH (k:K) RETURN k")

    keywords = GliderMetrics.snapshot().cypher |> Enum.map(& &1.keyword)

    assert "MATCH" in keywords
    assert "CREATE" in keywords or "INDEX" in keywords
  end

  test "keeps a per-second series for the recent window", %{graph: graph} do
    {:ok, _} = Context.assert(graph, "s:1", ["S"], %{})

    series = GliderMetrics.snapshot().series

    assert series != []
    assert Enum.all?(series, &is_integer(&1.at))
    assert Enum.sum(Enum.map(series, & &1.calls)) > 0
  end

  test "the latency reservoir stays bounded however much work is done", %{graph: graph} do
    limit = GliderMetrics.snapshot().sample_limit

    for i <- 1..(limit + 150) do
      {:ok, _} = Context.assert(graph, "bound:#{i}", ["B"], %{"v" => i})
    end

    run = op(GliderMetrics.snapshot(), :run)

    # Every call is still counted...
    assert run.calls >= limit + 150
    # ...but the memory behind the percentiles does not grow with them.
    assert run.p99_us > 0
    assert :ets.info(:jido_swarm_glider_metrics, :size) < limit * 3
  end

  test "reset clears everything", %{graph: graph} do
    {:ok, _} = Context.assert(graph, "r:1", ["R"], %{})
    assert GliderMetrics.snapshot().totals.calls > 0

    GliderMetrics.reset()
    assert GliderMetrics.snapshot().totals.calls == 0
  end
end
