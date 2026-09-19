defmodule JidoTest.Sensor.TranslationTest do
  use ExUnit.Case, async: true

  alias Jido.Sensor.Spec

  defmodule SimpleSensor do
    @moduledoc false
    use Jido.Sensor,
      name: "simple_sensor",
      description: "A simple test sensor that translates events to signals",
      schema:
        Zoi.object(
          %{
            prefix: Zoi.string() |> Zoi.default("test")
          },
          coerce: true
        )

    @impl Jido.Sensor
    def init(config, context) do
      state = %{
        prefix: config.prefix,
        context: context,
        event_count: 0
      }

      {:ok, state}
    end

    @impl Jido.Sensor
    def handle_event({:data, value}, state) do
      signal =
        Jido.Signal.new!(%{
          source: "/sensor/#{state.prefix}",
          type: "#{state.prefix}.data.received",
          data: %{value: value, count: state.event_count + 1}
        })

      new_state = %{state | event_count: state.event_count + 1}
      {:ok, new_state, [signal]}
    end

    def handle_event(:empty, state) do
      {:ok, state, []}
    end

    def handle_event({:error, reason}, _state) do
      {:error, reason}
    end
  end

  defmodule SchedulingSensor do
    @moduledoc false
    use Jido.Sensor,
      name: "scheduling_sensor",
      description: "A sensor that uses scheduling directives"

    @impl Jido.Sensor
    def init(config, context) do
      interval = Map.get(config, :interval, 1000)

      state = %{
        interval: interval,
        context: context,
        tick_count: 0
      }

      {:ok, state, [{:schedule, interval}]}
    end

    @impl Jido.Sensor
    def handle_event(:tick, state) do
      signal =
        Jido.Signal.new!(%{
          source: "/sensor/scheduling",
          type: "sensor.tick",
          data: %{tick: state.tick_count + 1}
        })

      new_state = %{state | tick_count: state.tick_count + 1}
      {:ok, new_state, [signal], [{:schedule, state.interval}]}
    end

    def handle_event({:tick_with_payload, payload}, state) do
      signal =
        Jido.Signal.new!(%{
          source: "/sensor/scheduling",
          type: "sensor.custom_tick",
          data: %{payload: payload, tick: state.tick_count + 1}
        })

      new_state = %{state | tick_count: state.tick_count + 1}
      {:ok, new_state, [signal], [{:schedule, state.interval, :custom_payload}]}
    end
  end

  defmodule MinimalSensor do
    @moduledoc false
    use Jido.Sensor,
      name: "minimal_sensor",
      description: "A minimal sensor with no schema"

    @impl Jido.Sensor
    def init(_config, _context) do
      {:ok, %{}}
    end

    @impl Jido.Sensor
    def handle_event(_event, state) do
      {:ok, state, []}
    end
  end

  describe "SimpleSensor metadata" do
    test "name/0 returns the configured name" do
      assert SimpleSensor.name() == "simple_sensor"
    end

    test "description/0 returns the configured description" do
      assert SimpleSensor.description() ==
               "A simple test sensor that translates events to signals"
    end

    test "schema/0 returns the Zoi schema" do
      schema = SimpleSensor.schema()
      assert schema != nil
    end

    test "spec/0 returns a Sensor.Spec struct" do
      spec = SimpleSensor.spec()

      assert %Spec{} = spec
      assert spec.module == SimpleSensor
      assert spec.name == "simple_sensor"
      assert spec.description == "A simple test sensor that translates events to signals"
      assert spec.schema != nil
    end

    test "__sensor_metadata__/0 returns metadata map" do
      metadata = SimpleSensor.__sensor_metadata__()

      assert is_map(metadata)
      assert metadata.name == "simple_sensor"
      assert metadata.description == "A simple test sensor that translates events to signals"
      assert metadata.schema != nil
    end
  end

  describe "MinimalSensor metadata" do
    test "name/0 returns the configured name" do
      assert MinimalSensor.name() == "minimal_sensor"
    end

    test "description/0 returns the configured description" do
      assert MinimalSensor.description() == "A minimal sensor with no schema"
    end

    test "schema/0 returns nil when not configured" do
      assert MinimalSensor.schema() == nil
    end

    test "spec/0 returns a Sensor.Spec with optional fields" do
      spec = MinimalSensor.spec()

      assert %Spec{} = spec
      assert spec.module == MinimalSensor
      assert spec.name == "minimal_sensor"
    end

    test "__sensor_metadata__/0 returns metadata with description and nil schema" do
      metadata = MinimalSensor.__sensor_metadata__()

      assert metadata.name == "minimal_sensor"
      assert metadata.description == "A minimal sensor with no schema"
      assert metadata.schema == nil
    end
  end

  describe "SimpleSensor.init/2" do
    test "returns initial state with config values" do
      config = %{prefix: "custom"}
      context = %{sensor_id: "sensor-123"}

      {:ok, state} = SimpleSensor.init(config, context)

      assert state.prefix == "custom"
      assert state.context == context
      assert state.event_count == 0
    end

    test "uses config prefix in state" do
      config = %{prefix: "default"}
      context = %{}

      {:ok, state} = SimpleSensor.init(config, context)

      assert state.prefix == "default"
      assert state.event_count == 0
    end
  end

  describe "SimpleSensor.handle_event/2" do
    test "translates data event to signal" do
      state = %{prefix: "test", event_count: 0}

      {:ok, new_state, signals} = SimpleSensor.handle_event({:data, 42}, state)

      assert new_state.event_count == 1
      assert [signal] = signals
      assert signal.source == "/sensor/test"
      assert signal.type == "test.data.received"
      assert signal.data.value == 42
      assert signal.data.count == 1
    end

    test "increments event count on each event" do
      state = %{prefix: "test", event_count: 5}

      {:ok, new_state, [signal]} = SimpleSensor.handle_event({:data, "value"}, state)

      assert new_state.event_count == 6
      assert signal.data.count == 6
    end

    test "returns empty signals list for empty event" do
      state = %{prefix: "test", event_count: 0}

      {:ok, new_state, signals} = SimpleSensor.handle_event(:empty, state)

      assert new_state == state
      assert signals == []
    end

    test "returns error tuple for error events" do
      state = %{prefix: "test", event_count: 0}

      result = SimpleSensor.handle_event({:error, :something_wrong}, state)

      assert {:error, :something_wrong} = result
    end
  end

  describe "SchedulingSensor.init/2" do
    test "returns initial state with schedule directive" do
      config = %{interval: 2000}
      context = %{agent_ref: :some_ref}

      {:ok, state, directives} = SchedulingSensor.init(config, context)

      assert state.interval == 2000
      assert state.context == context
      assert state.tick_count == 0
      assert [{:schedule, 2000}] = directives
    end

    test "uses default interval when not specified" do
      config = %{}
      context = %{}

      {:ok, state, directives} = SchedulingSensor.init(config, context)

      assert state.interval == 1000
      assert [{:schedule, 1000}] = directives
    end
  end

  describe "SchedulingSensor.handle_event/2" do
    test "handles tick event and returns signal with schedule directive" do
      state = %{interval: 500, tick_count: 0}

      {:ok, new_state, signals, directives} = SchedulingSensor.handle_event(:tick, state)

      assert new_state.tick_count == 1
      assert [signal] = signals
      assert signal.source == "/sensor/scheduling"
      assert signal.type == "sensor.tick"
      assert signal.data.tick == 1
      assert [{:schedule, 500}] = directives
    end

    test "handles tick with payload and returns schedule directive with payload" do
      state = %{interval: 1000, tick_count: 2}

      {:ok, new_state, signals, directives} =
        SchedulingSensor.handle_event({:tick_with_payload, %{extra: "data"}}, state)

      assert new_state.tick_count == 3
      assert [signal] = signals
      assert signal.type == "sensor.custom_tick"
      assert signal.data.payload == %{extra: "data"}
      assert signal.data.tick == 3
      assert [{:schedule, 1000, :custom_payload}] = directives
    end

    test "increments tick count correctly" do
      state = %{interval: 100, tick_count: 10}

      {:ok, new_state, [signal], _directives} = SchedulingSensor.handle_event(:tick, state)

      assert new_state.tick_count == 11
      assert signal.data.tick == 11
    end
  end

  describe "SchedulingSensor metadata" do
    test "spec/0 returns valid Sensor.Spec" do
      spec = SchedulingSensor.spec()

      assert %Spec{} = spec
      assert spec.module == SchedulingSensor
      assert spec.name == "scheduling_sensor"
      assert spec.description == "A sensor that uses scheduling directives"
    end
  end

  describe "terminate/2 default implementation" do
    test "SimpleSensor terminate returns :ok" do
      assert :ok = SimpleSensor.terminate(:normal, %{})
    end

    test "SchedulingSensor terminate returns :ok" do
      assert :ok = SchedulingSensor.terminate(:shutdown, %{some: :state})
    end

    test "MinimalSensor terminate returns :ok" do
      assert :ok = MinimalSensor.terminate({:error, :reason}, %{})
    end
  end
end
