defmodule JidoSwarm.GliderMetrics do
  @moduledoc """
  What Glider is doing, and how well it is doing it.

  Attaches to the telemetry `Jido.Context.Engine.Glider` emits and keeps a
  rolling picture in ETS: per-operation counts, latency distribution, error
  rate, throughput, and a recent time series.

  ## Why percentiles and not an average

  Graph work is bimodal — an indexed lookup is microseconds and a `CALL
  pagerank` is seconds — so a mean sits in the empty space between the two
  and describes nothing that ever happens. p50/p95/p99 answer the question an
  operator actually has, which is "how bad does it get".

  Latencies are kept in a bounded reservoir per operation (the most recent
  `@sample_limit`), so memory is constant regardless of how long the process
  runs. That makes the percentiles *recent* rather than all-time, which is the
  more useful reading for a live dashboard and the reason they are labelled as
  such in the UI.

  ## Why ETS rather than a GenServer's state

  Telemetry handlers run in the *calling* process, on the hot path of every
  graph operation. Sending each one to a GenServer would serialise all graph
  work behind a single mailbox — the collector would become the bottleneck it
  exists to measure. Writes go straight to a public ETS table with
  `write_concurrency`, and the owning process exists only to hold the table.
  """

  use GenServer

  alias Jido.Context.Engine.Glider

  @table :jido_swarm_glider_metrics
  @series :jido_swarm_glider_series

  # Per-operation latency reservoir. 512 samples is enough for a stable p99 and
  # small enough that the whole table stays trivial in memory.
  @sample_limit 512

  # One bucket per second, kept for this many seconds.
  @series_window 300

  @handler_id "jido-swarm-glider-metrics"

  @operations [:open, :query, :run, :import, :export, :checkpoint, :stats]

  # ===========================================================================
  # Lifecycle
  # ===========================================================================

  @doc false
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    :ets.new(@table, [:set, :public, :named_table, write_concurrency: true])
    :ets.new(@series, [:ordered_set, :public, :named_table, write_concurrency: true])

    attach()
    schedule_trim()

    {:ok, %{}}
  end

  @doc """
  Attaches the telemetry handlers. Idempotent.
  """
  @spec attach() :: :ok
  def attach do
    _ = :telemetry.detach(@handler_id)

    :telemetry.attach_many(
      @handler_id,
      Glider.telemetry_events(),
      &__MODULE__.handle_event/4,
      nil
    )
  end

  @impl true
  def handle_info(:trim, state) do
    trim_series()
    schedule_trim()
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp schedule_trim, do: Process.send_after(self(), :trim, 30_000)

  # ===========================================================================
  # Recording
  # ===========================================================================

  @doc false
  def handle_event([:jido, :context, :glider, op, :stop], measurements, metadata, _config) do
    duration_us = System.convert_time_unit(measurements.duration, :native, :microsecond)
    result = Map.get(metadata, :result, :ok)

    bump({:count, op, result})
    bump({:duration_total, op}, duration_us)
    record_sample(op, duration_us)
    record_max(op, duration_us)

    # Work done, as distinct from work requested: rows read and entities
    # written are what says whether the graph is actually being used.
    if rows = Map.get(metadata, :rows), do: bump({:rows, op}, rows)
    if touched = Map.get(metadata, :touched), do: bump({:touched, op}, touched)
    if bytes = Map.get(metadata, :bytes), do: bump({:bytes, op}, bytes)

    if keyword = Map.get(metadata, :operation), do: bump({:cypher, keyword, result})

    record_series(op, result, duration_us)
    :ok
  end

  def handle_event([:jido, :context, :glider, op, :exception], _measurements, _metadata, _config) do
    bump({:count, op, :exception})
    :ok
  end

  def handle_event(_event, _measurements, _metadata, _config), do: :ok

  defp bump(key, by \\ 1) do
    :ets.update_counter(@table, key, by, {key, 0})
  rescue
    ArgumentError -> :ok
  end

  # A bounded ring per operation: the slot cycles, so the reservoir holds the
  # most recent @sample_limit durations and never grows.
  defp record_sample(op, duration_us) do
    slot = :ets.update_counter(@table, {:slot, op}, 1, {{:slot, op}, 0})
    :ets.insert(@table, {{:sample, op, rem(slot, @sample_limit)}, duration_us})
  rescue
    ArgumentError -> :ok
  end

  defp record_max(op, duration_us) do
    key = {:max, op}

    case :ets.lookup(@table, key) do
      [{^key, current}] when current >= duration_us -> :ok
      _ -> :ets.insert(@table, {key, duration_us})
    end
  rescue
    ArgumentError -> :ok
  end

  defp record_series(op, result, duration_us) do
    second = System.system_time(:second)
    :ets.update_counter(@series, {second, :calls}, 1, {{second, :calls}, 0})
    :ets.update_counter(@series, {second, :duration}, duration_us, {{second, :duration}, 0})

    if result == :error do
      :ets.update_counter(@series, {second, :errors}, 1, {{second, :errors}, 0})
    end

    :ets.update_counter(@series, {second, {:op, op}}, 1, {{second, {:op, op}}, 0})
  rescue
    ArgumentError -> :ok
  end

  defp trim_series do
    cutoff = System.system_time(:second) - @series_window
    :ets.select_delete(@series, [{{{:"$1", :_}, :_}, [{:<, :"$1", cutoff}], [true]}])
  rescue
    ArgumentError -> 0
  end

  # ===========================================================================
  # Reading
  # ===========================================================================

  @doc """
  Everything the dashboard needs, in one read.
  """
  @spec snapshot() :: map()
  def snapshot do
    operations = Enum.map(@operations, &operation_stats/1) |> Enum.reject(&(&1.calls == 0))

    total_calls = Enum.sum(Enum.map(operations, & &1.calls))
    total_errors = Enum.sum(Enum.map(operations, & &1.errors))

    %{
      operations: operations,
      cypher: cypher_stats(),
      totals: %{
        calls: total_calls,
        errors: total_errors,
        error_rate: rate(total_errors, total_calls),
        rows: Enum.sum(Enum.map(operations, & &1.rows)),
        touched: Enum.sum(Enum.map(operations, & &1.touched)),
        busy_us: Enum.sum(Enum.map(operations, & &1.total_us))
      },
      series: series(),
      window_seconds: @series_window,
      sample_limit: @sample_limit
    }
  rescue
    ArgumentError -> empty_snapshot()
  end

  @doc "An empty snapshot, for before the table exists."
  @spec empty_snapshot() :: map()
  def empty_snapshot do
    %{
      operations: [],
      cypher: [],
      totals: %{calls: 0, errors: 0, error_rate: 0.0, rows: 0, touched: 0, busy_us: 0},
      series: [],
      window_seconds: @series_window,
      sample_limit: @sample_limit
    }
  end

  defp operation_stats(op) do
    ok = counter({:count, op, :ok})
    errors = counter({:count, op, :error}) + counter({:count, op, :exception})
    calls = ok + errors
    total_us = counter({:duration_total, op})
    samples = samples(op)

    %{
      operation: op,
      calls: calls,
      errors: errors,
      error_rate: rate(errors, calls),
      rows: counter({:rows, op}),
      touched: counter({:touched, op}),
      bytes: counter({:bytes, op}),
      total_us: total_us,
      mean_us: if(calls > 0, do: div(total_us, calls), else: 0),
      p50_us: percentile(samples, 50),
      p95_us: percentile(samples, 95),
      p99_us: percentile(samples, 99),
      max_us: counter({:max, op})
    }
  end

  defp cypher_stats do
    @table
    |> :ets.match({{:cypher, :"$1", :"$2"}, :"$3"})
    |> Enum.reduce(%{}, fn [keyword, result, count], acc ->
      Map.update(acc, keyword, {count_for(result, count), count}, fn {errors, total} ->
        {errors + count_for(result, count), total + count}
      end)
    end)
    |> Enum.map(fn {keyword, {errors, total}} ->
      %{keyword: keyword, calls: total, errors: errors, error_rate: rate(errors, total)}
    end)
    |> Enum.sort_by(& &1.calls, :desc)
  end

  defp count_for(:error, count), do: count
  defp count_for(_, _count), do: 0

  @doc """
  Per-second activity over the retained window, oldest first.
  """
  @spec series() :: [map()]
  def series do
    now = System.system_time(:second)
    from = now - @series_window

    buckets =
      @series
      |> :ets.select([{{{:"$1", :"$2"}, :"$3"}, [{:>=, :"$1", from}], [{{:"$1", :"$2", :"$3"}}]}])
      |> Enum.reduce(%{}, fn {second, field, value}, acc ->
        Map.update(acc, second, %{field => value}, &Map.put(&1, field, value))
      end)

    buckets
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {second, fields} ->
      calls = Map.get(fields, :calls, 0)
      duration = Map.get(fields, :duration, 0)

      %{
        at: second,
        calls: calls,
        errors: Map.get(fields, :errors, 0),
        mean_us: if(calls > 0, do: div(duration, calls), else: 0)
      }
    end)
  rescue
    ArgumentError -> []
  end

  @doc "Clears every recorded metric. For tests, and for the UI's reset."
  @spec reset() :: :ok
  def reset do
    :ets.delete_all_objects(@table)
    :ets.delete_all_objects(@series)
    :ok
  rescue
    ArgumentError -> :ok
  end

  # ===========================================================================
  # Helpers
  # ===========================================================================

  defp counter(key) do
    case :ets.lookup(@table, key) do
      [{^key, value}] -> value
      [] -> 0
    end
  rescue
    ArgumentError -> 0
  end

  defp samples(op) do
    @table
    |> :ets.match({{:sample, op, :_}, :"$1"})
    |> List.flatten()
    |> Enum.sort()
  rescue
    ArgumentError -> []
  end

  # Nearest-rank: with a bounded reservoir there is no benefit to interpolating
  # between samples, and the rank is easier to reason about when reading a
  # dashboard.
  defp percentile([], _), do: 0

  defp percentile(sorted, p) do
    index =
      (length(sorted) * p / 100)
      |> Float.ceil()
      |> trunc()
      |> max(1)
      |> min(length(sorted))

    Enum.at(sorted, index - 1)
  end

  defp rate(_errors, 0), do: 0.0
  defp rate(errors, calls), do: Float.round(errors / calls * 100, 2)
end
