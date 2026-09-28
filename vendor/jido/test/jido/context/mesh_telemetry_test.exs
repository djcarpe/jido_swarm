defmodule Jido.Context.MeshTelemetryTest do
  use ExUnit.Case, async: false

  alias Jido.Context
  alias Jido.Context.Delta
  alias Jido.Context.Graph
  alias Jido.Context.Mesh

  @moduletag :glider

  defp unique(prefix), do: :"#{prefix}_#{System.unique_integer([:positive])}"

  setup do
    if Context.available?() do
      handler = "mesh-telemetry-#{System.unique_integer([:positive])}"
      test = self()

      :ok =
        :telemetry.attach_many(
          handler,
          Mesh.telemetry_events() ++ Graph.telemetry_events(),
          fn event, measurements, metadata, _ ->
            send(test, {:telemetry, event, measurements, metadata})
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler) end)

      mesh = unique(:mesh)
      start_supervised!({Mesh, name: mesh, transports: []}, id: mesh)
      a = unique(:a)
      b = unique(:b)
      start_supervised!({Graph, name: a, origin: "a", mesh: mesh, location: :memory}, id: a)
      start_supervised!({Graph, name: b, origin: "b", mesh: mesh, location: :memory}, id: b)
      {:ok, mesh: mesh, a: a, b: b}
    else
      {:ok, skip: true}
    end
  end

  describe "the router" do
    test "counts what goes out, what comes in, and what it drops", %{mesh: mesh} do
      :ok = Mesh.subscribe(mesh, ["**"])
      delta = Delta.new("t", "o", 1, [])

      :ok = Mesh.publish(mesh, delta)

      assert_receive {:telemetry, [:jido, :context, :mesh, :publish],
                      %{count: 1, ops: 0, subscribers: n},
                      %{mesh: ^mesh, origin: "o", topic: "t", seq: 1}}

      # This test process plus the two graphs.
      assert n == 3

      :ok = Mesh.deliver(mesh, delta)

      assert_receive {:telemetry, [:jido, :context, :mesh, :duplicate], %{count: 1},
                      %{mesh: ^mesh}}

      :ok = Mesh.deliver(mesh, Delta.new("t", "o", 2, []))
      assert_receive {:telemetry, [:jido, :context, :mesh, :deliver], %{count: 1}, %{seq: 2}}
    end
  end

  describe "the graph" do
    test "a delta that applies cleanly is one event with the tally", %{a: a, b: b} do
      {:ok, delta} =
        Context.commit(a, [
          {:put_node, "n:1", ["Thing"], %{"v" => 1}},
          {:put_edge, "n:1", "REL", "n:2", %{}}
        ])

      id = delta.id

      # Once on the writer, marked local, and once on the peer, not.
      assert_receive {:telemetry, [:jido, :context, :delta, :applied],
                      %{ops: 2, applied: 2, superseded: 0, tombstoned: 0, duration: d},
                      %{
                        graph: ^a,
                        id: ^id,
                        origin: "a",
                        local: true,
                        outcomes: [:applied, :applied]
                      }}

      assert is_integer(d) and d >= 0

      assert_receive {:telemetry, [:jido, :context, :delta, :applied], %{applied: 2},
                      %{graph: ^b, id: ^id, local: false}}
    end

    test "a write that loses to a higher stamp is superseded, not applied", %{a: a} do
      {:ok, _} = Context.assert(a, "n:1", ["Thing"], %{"v" => "kept"})
      assert_receive {:telemetry, [:jido, :context, :delta, :applied], _, %{graph: ^a}}

      # A stale delta from elsewhere: sequence 0 cannot beat what is there.
      stale = Delta.new("context", "z", 0, [{:put_node, "n:1", ["Thing"], %{"v" => "stale"}}])
      :ok = Graph.apply_delta(a, stale)
      :ok = Context.sync(a)

      stale_id = stale.id

      assert_receive {:telemetry, [:jido, :context, :delta, :applied],
                      %{ops: 1, applied: 0, superseded: 1, tombstoned: 0},
                      %{
                        graph: ^a,
                        id: ^stale_id,
                        origin: "z",
                        local: false,
                        outcomes: [:superseded]
                      }}

      assert {:ok, %{props: %{"v" => "kept"}}} = Context.fetch(a, "n:1")
    end

    test "a write that loses to a deletion is tombstoned", %{a: a} do
      {:ok, _} = Context.assert(a, "n:1", ["Thing"], %{"v" => 1})
      {:ok, _} = Context.retract(a, "n:1")

      assert_receive {:telemetry, [:jido, :context, :delta, :applied], %{applied: 1},
                      %{outcomes: [:applied]}}

      assert_receive {:telemetry, [:jido, :context, :delta, :applied], %{applied: 1},
                      %{outcomes: [:applied]}}

      stale = Delta.new("context", "z", 0, [{:put_node, "n:1", ["Thing"], %{"v" => "back"}}])
      :ok = Graph.apply_delta(a, stale)
      :ok = Context.sync(a)

      assert_receive {:telemetry, [:jido, :context, :delta, :applied],
                      %{ops: 1, applied: 0, superseded: 0, tombstoned: 1},
                      %{outcomes: [:tombstoned]}}

      assert :not_found = Context.fetch(a, "n:1")
    end

    test "edges and edge drops report the same way", %{a: a} do
      {:ok, _} = Context.commit(a, [{:put_node, "x", [], %{}}, {:put_node, "y", [], %{}}])
      {:ok, _} = Context.relate(a, "x", "REL", "y", %{"w" => 2})
      assert_receive {:telemetry, [:jido, :context, :delta, :applied], %{ops: 2}, _}

      assert_receive {:telemetry, [:jido, :context, :delta, :applied], %{ops: 1, applied: 1},
                      %{outcomes: [:applied]}}

      stale =
        Delta.new("context", "z", 0, [
          {:put_edge, "x", "REL", "y", %{"w" => 9}},
          {:drop_edge, "x", "REL", "y"}
        ])

      :ok = Graph.apply_delta(a, stale)
      :ok = Context.sync(a)

      assert_receive {:telemetry, [:jido, :context, :delta, :applied],
                      %{ops: 2, applied: 0, superseded: 2},
                      %{outcomes: [:superseded, :superseded]}}
    end

    test "the event names are listed" do
      assert Graph.telemetry_events() == [
               [:jido, :context, :delta, :applied],
               [:jido, :context, :delta, :failed]
             ]

      assert length(Mesh.telemetry_events()) == 3
    end
  end
end
