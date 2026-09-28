defmodule Jido.Context.Mesh.Router do
  @moduledoc """
  The process behind a `Jido.Context.Mesh`: subscriptions, topic matching and
  duplicate suppression.

  Started by `Jido.Context.Mesh`; not meant to be addressed directly — the
  mesh's public functions are the interface.
  """

  use GenServer

  require Logger

  alias Jido.Context.Delta
  alias Jido.Context.Mesh

  # The de-duplication window. Bounded on purpose: this suppresses the echo of a
  # delta the mesh itself just published, not every delta ever seen. Anything
  # older has already been applied, and applying it again is a no-op.
  @seen_limit 4096

  defmodule State do
    @moduledoc false
    @type t :: %__MODULE__{}
    defstruct [
      :name,
      :transports,
      subscribers: %{},
      seen: :queue.new(),
      seen_set: MapSet.new()
    ]
  end

  @doc false
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: Mesh.router_name(name))
  end

  @impl true
  def init(opts) do
    {:ok,
     %State{
       name: Keyword.fetch!(opts, :name),
       transports: Keyword.fetch!(opts, :transports)
     }}
  end

  @impl true
  def handle_call({:subscribe, pid, patterns}, _from, state) do
    Process.monitor(pid)
    {:reply, :ok, put_in(state.subscribers[pid], patterns)}
  end

  def handle_call({:unsubscribe, pid}, _from, state) do
    {:reply, :ok, update_in(state.subscribers, &Map.delete(&1, pid))}
  end

  def handle_call(:subscribers, _from, state), do: {:reply, state.subscribers, state}

  def handle_call(:sync, _from, state), do: {:reply, :ok, state}

  @impl true
  def handle_cast({:publish, delta}, state) do
    state = fanout(state, delta, :publish)

    for {mod, opts} <- state.transports do
      case mod.publish(delta, opts) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "jido context mesh #{inspect(state.name)}: #{inspect(mod)} could not publish " <>
              "#{delta.id} on #{delta.topic}: #{inspect(reason)}"
          )
      end
    end

    {:noreply, state}
  end

  def handle_cast({:deliver, delta}, state), do: {:noreply, fanout(state, delta, :deliver)}

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, update_in(state.subscribers, &Map.delete(&1, pid))}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # One telemetry event per delta, whichever way it went: `:publish` for a
  # local write going out, `:deliver` for one arriving over a transport, and
  # `:duplicate` for an echo the window caught. Measuring here rather than in
  # the graph is what makes "how much is arriving" and "how much is applied"
  # two different numbers, which they are.
  defp fanout(state, %Delta{} = delta, kind) do
    metadata = %{
      mesh: state.name,
      id: delta.id,
      origin: delta.origin,
      topic: delta.topic,
      seq: delta.seq,
      ts: delta.ts
    }

    if MapSet.member?(state.seen_set, delta.id) do
      :telemetry.execute([:jido, :context, :mesh, :duplicate], %{count: 1}, metadata)
      state
    else
      delivered =
        for {pid, patterns} <- state.subscribers,
            Enum.any?(patterns, &Delta.topic_match?(delta.topic, &1)) do
          send(pid, {:jido_context_delta, state.name, delta})
        end

      :telemetry.execute(
        [:jido, :context, :mesh, kind],
        %{count: 1, ops: length(delta.ops), subscribers: length(delivered)},
        metadata
      )

      remember(state, delta.id)
    end
  end

  defp remember(state, id) do
    queue = :queue.in(id, state.seen)
    set = MapSet.put(state.seen_set, id)

    if :queue.len(queue) > @seen_limit do
      {{:value, oldest}, queue} = :queue.out(queue)
      %{state | seen: queue, seen_set: MapSet.delete(set, oldest)}
    else
      %{state | seen: queue, seen_set: set}
    end
  end
end
