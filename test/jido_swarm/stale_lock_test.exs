defmodule JidoSwarm.StaleLockTest do
  @moduledoc """
  The failure this guards against took the deployed swarm down for five days.

  Glider locks the graph file against a second writer. In a container that
  inverts: the lock records the holder's pid, every containerised BEAM is pid 1,
  and the volume outlives the process — so after any hard exit the next start
  finds a lock "held by pid 1", which is itself one incarnation ago, and
  refuses. Observed as 741 restarts of a pod that could never boot again.
  """

  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    graph_path = Path.join([tmp_dir, "graph", "swarm.gldb"])
    File.mkdir_p!(Path.dirname(graph_path))

    previous = Application.get_env(:jido_swarm, :context, [])

    Application.put_env(
      :jido_swarm,
      :context,
      Keyword.merge(previous, location: {:disk, path: graph_path}, store: nil)
    )

    on_exit(fn ->
      Application.put_env(:jido_swarm, :context, previous)
      System.delete_env("SWARM_SINGLE_WRITER")
    end)

    {:ok, graph_path: graph_path, lock: graph_path <> ".lock"}
  end

  test "a real graph survives being reopened after a stale lock is left behind",
       %{graph_path: graph_path, lock: lock} do
    name = :"stale_lock_#{System.unique_integer([:positive])}"

    # Open a disk-backed graph, write something, and confirm Glider took a lock.
    {:ok, pid} =
      Jido.Context.Graph.start_link(name: name, location: {:disk, path: graph_path}, origin: "a")

    {:ok, _} = Jido.Context.assert(name, "thing:1", ["Thing"], %{"v" => 1})
    assert File.exists?(lock)

    # Close cleanly, then put the lock back by hand holding a *live* pid.
    #
    # Killing the owning Elixir process is not the failure being reproduced:
    # the NIF releases the lock when its resource is collected, so an in-VM
    # kill tidies up after itself. What a crashed container leaves is a lock
    # file on disk naming a pid that is alive — because in a container the new
    # BEAM is pid 1, the same pid the dead one had. Writing our own OS pid
    # reproduces exactly that: a lock whose holder looks alive but is not the
    # holder any more.
    :ok = GenServer.stop(pid, :normal, 5_000)
    File.write!(lock, to_string(System.pid()))

    assert File.exists?(lock)

    # Reopening now fails, which is the wedge.
    Process.flag(:trap_exit, true)

    result =
      Jido.Context.Graph.start_link(name: name, location: {:disk, path: graph_path}, origin: "a")

    assert {:error, {:graph_open_failed, reason}} = result
    assert inspect(reason) =~ "lock"

    # Clearing the stale lock is what lets it boot again — and the data written
    # before the crash is still there, which is the point of the disk file.
    File.rm!(lock)

    {:ok, pid2} =
      Jido.Context.Graph.start_link(name: name, location: {:disk, path: graph_path}, origin: "a")

    # Linked to the test process, so it is already going down by the time
    # on_exit runs; stopping it is worth doing to release the lock promptly but
    # must tolerate losing the race.
    on_exit(fn ->
      if Process.alive?(pid2) do
        try do
          GenServer.stop(pid2, :normal, 1_000)
        catch
          :exit, _ -> :ok
        end
      end
    end)

    assert {:ok, %{rows: [[1]]}} = Jido.Context.query(name, "MATCH (t:Thing) RETURN t.v")
  end
end
