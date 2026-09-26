defmodule Jido.Context.GliderTelemetryTest do
  @moduledoc """
  Every graph operation must be measurable, including the ones that fail.

  A failed query that emitted no measurement would make an outage look like
  idleness, so `:result` is asserted on both paths.
  """

  use ExUnit.Case, async: false

  alias Jido.Context
  alias Jido.Context.Engine.Glider
  alias Jido.Context.Graph

  setup do
    unless Context.available?() do
      raise "these tests exercise the real engine"
    end

    name = :"tel_#{System.unique_integer([:positive])}"
    pid = start_supervised!({Graph, name: name, location: :memory})
    assert is_pid(pid)

    handler = "test-#{System.unique_integer([:positive])}"
    parent = self()

    :ok =
      :telemetry.attach_many(
        handler,
        Glider.telemetry_events(),
        fn event, measurements, metadata, _ ->
          send(parent, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    {:ok, graph: name}
  end

  test "a query emits start and stop with a duration and a row count", %{graph: graph} do
    {:ok, _} = Context.assert(graph, "a", ["Thing"], %{"v" => 1})
    flush()

    {:ok, _} = Context.query(graph, "MATCH (t:Thing) RETURN t.v")

    assert_receive {:telemetry, [:jido, :context, :glider, :query, :start], _, _}
    assert_receive {:telemetry, [:jido, :context, :glider, :query, :stop], measurements, metadata}

    assert is_integer(measurements.duration)
    assert metadata.result == :ok
    assert metadata.rows == 1
    assert metadata.operation == "MATCH"
    assert metadata.statement_bytes > 0
  end

  test "a write emits the number of entities it touched", %{graph: graph} do
    {:ok, _} = Context.assert(graph, "b", ["Thing"], %{"v" => 2})

    assert_receive {:telemetry, [:jido, :context, :glider, :run, :stop], _, metadata}
    assert metadata.result == :ok
    assert is_integer(metadata.touched)
  end

  test "a failing query is still measured, and is marked as an error", %{graph: graph} do
    {:error, _} = Context.query(graph, "THIS IS NOT CYPHER")

    assert_receive {:telemetry, [:jido, :context, :glider, :query, :stop], measurements, metadata}

    assert is_integer(measurements.duration)
    assert metadata.result == :error
    assert metadata.operation == "THIS"
  end

  test "the statement text itself is never put in metadata", %{graph: graph} do
    # Entity keys and property values routinely contain user data; the leading
    # keyword is the grouping dimension, and the rest must not be recorded.
    secret = "super-secret-value-do-not-log"
    {:ok, _} = Context.assert(graph, "c", ["Thing"], %{"v" => secret})

    assert_receive {:telemetry, [:jido, :context, :glider, :run, :stop], _, metadata}

    refute metadata |> inspect() |> String.contains?(secret)
  end

  test "stats and export are measured too", %{graph: graph} do
    {:ok, _} = Context.stats(graph)
    assert_receive {:telemetry, [:jido, :context, :glider, :stats, :stop], _, %{result: :ok}}

    {:ok, _} = Context.export(graph)
    assert_receive {:telemetry, [:jido, :context, :glider, :export, :stop], _, %{result: :ok}}
  end

  test "telemetry_events/0 lists every operation in all three phases" do
    events = Glider.telemetry_events()

    assert length(events) == 7 * 3

    for op <- [:open, :query, :run, :import, :export, :checkpoint, :stats] do
      assert [:jido, :context, :glider, op, :stop] in events
    end
  end

  defp flush do
    receive do
      {:telemetry, _, _, _} -> flush()
    after
      0 -> :ok
    end
  end
end
