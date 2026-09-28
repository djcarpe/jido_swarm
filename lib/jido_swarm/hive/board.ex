defmodule JidoSwarm.Hive.Board do
  @moduledoc """
  The shared board: goals, the tasks under them, and how tasks depend on and
  break down into one another.

      (:HiveGoal)─[:HAS_TASK]→(:HiveTask)─[:SUBTASK_OF]→(:HiveTask)
                                   │
                              [:DEPENDS_ON]→(:HiveTask)

  A task's **status is derived**, never stored on the task: it comes from the
  task's claim (see `JidoSwarm.Hive.Claims`), its dependencies and its
  subtasks. That keeps the task node write-once, which is what makes it safe to
  replicate:

  | status | when |
  |---|---|
  | `open` | nobody holds it (or their lease ran out), dependencies are done |
  | `blocked` | a dependency is not done yet |
  | `claimed` | an agent holds a live lease |
  | `split` | it was broken into subtasks that are not all done |
  | `done` | completed — or split and every subtask is done |
  | `failed` | failed `max_attempts` times |

  Anyone may add a goal or a task; decomposition is how the swarm organises
  itself around a problem too big for one agent: the agent that claims a big
  task splits it and releases the pieces to the board.
  """

  alias JidoSwarm.Hive.Claims
  alias JidoSwarm.Hive.Store

  @max_attempts 3

  @doc """
  Adds a goal: a top-level objective the swarm organises around.
  """
  @spec add_goal(map()) :: {:ok, String.t()} | {:error, term()}
  def add_goal(attrs) do
    key = "goal:" <> Store.new_id("g")

    props = %{
      title: req!(attrs, :title),
      description: get(attrs, :description, ""),
      priority: priority(get(attrs, :priority, 3)),
      created_by: get(attrs, :created_by, "unknown"),
      created_at: Store.now()
    }

    with :ok <- Store.put(key, ["HiveGoal"], props, :board), do: {:ok, key}
  end

  @doc """
  Adds a task. Attach it with `:goal` or `:parent` (a task key), order it with
  `:depends_on` (task keys), and say what it needs with `:skills`.
  """
  @spec add_task(map()) :: {:ok, String.t()} | {:error, term()}
  def add_task(attrs) do
    key = "task:" <> Store.new_id("t")
    parent = get(attrs, :parent, nil)
    goal = get(attrs, :goal, nil) || (parent && goal_of(parent))

    props = %{
      title: req!(attrs, :title),
      detail: get(attrs, :detail, ""),
      acceptance: get(attrs, :acceptance, ""),
      priority: priority(get(attrs, :priority, 3)),
      skills: JidoSwarm.Hive.Agents.normalize_skills(get(attrs, :skills, [])),
      created_by: get(attrs, :created_by, "unknown"),
      created_at: Store.now(),
      goal: goal || "",
      parent: parent || ""
    }

    edges =
      Enum.reject(
        [
          goal && {"IN_GOAL", goal, %{}},
          parent && {"SUBTASK_OF", parent, %{}}
        ],
        &is_nil/1
      ) ++ Enum.map(List.wrap(get(attrs, :depends_on, [])), &{"DEPENDS_ON", &1, %{}})

    with :ok <- Store.put(key, ["HiveTask"], props, edges, :board), do: {:ok, key}
  end

  @doc """
  Splits a task into subtasks. `subtasks` are task attribute maps; a subtask
  may depend on an earlier one by index (`depends_on: [0]`).

  The parent is marked `split` so nobody picks it up again; it becomes `done`
  when every subtask is.
  """
  @spec decompose(String.t(), [map()], String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def decompose(task_key, subtasks, agent_id) do
    keys =
      subtasks
      |> Enum.with_index()
      |> Enum.reduce_while({:ok, []}, fn {sub, _i}, {:ok, acc} ->
        deps =
          List.wrap(get(sub, :depends_on, []))
          |> Enum.map(fn
            i when is_integer(i) -> Enum.at(Enum.reverse(acc), i)
            k -> k
          end)
          |> Enum.reject(&is_nil/1)

        attrs =
          sub
          |> Map.new(fn {k, v} -> {to_string(k), v} end)
          |> Map.merge(%{"parent" => task_key, "depends_on" => deps, "created_by" => agent_id})

        case add_task(attrs) do
          {:ok, k} -> {:cont, {:ok, [k | acc]}}
          e -> {:halt, e}
        end
      end)

    with {:ok, rev} <- keys,
         :ok <-
           Claims.mark(task_key, agent_id, "split", %{
             summary: "split into #{length(rev)} subtasks"
           }) do
      {:ok, Enum.reverse(rev)}
    end
  end

  @doc "Records that `task` cannot start until `on` is done."
  @spec depend(String.t(), String.t()) :: :ok | {:error, term()}
  def depend(task, on), do: Store.relate(task, "DEPENDS_ON", on, %{}, :board)

  # ===========================================================================
  # Reading the board
  # ===========================================================================

  @doc "Every goal, with progress over its tasks."
  @spec goals() :: [map()]
  def goals do
    tasks = tasks()

    Store.all("HiveGoal", ~w(title description priority created_by created_at))
    |> Enum.map(fn g ->
      mine = Enum.filter(tasks, &(&1.goal == g.key))
      done = Enum.count(mine, &(&1.status == "done"))
      Map.merge(g, %{tasks: length(mine), done: done})
    end)
    |> Enum.sort_by(&{-(&1.priority || 0), &1.created_at})
  end

  @doc """
  Every task with its derived status, claim, dependencies and subtasks.
  """
  @spec tasks() :: [map()]
  def tasks do
    # A task node written by something other than add_task/1 — another tool
    # over MCP, a hand-run Cypher — may lack any of these; the board reads
    # them as their empty forms rather than crashing on the first render.
    raw =
      Store.all(
        "HiveTask",
        ~w(title detail acceptance priority skills created_by created_at goal parent)
      )
      |> Enum.map(fn t ->
        %{
          t
          | title: t.title || t.key,
            detail: t.detail || "",
            acceptance: t.acceptance || "",
            priority: t.priority || 3,
            skills: List.wrap(t.skills),
            goal: t.goal || "",
            parent: t.parent || ""
        }
      end)

    claims = Claims.all() |> Map.new(&{&1.task, &1})
    deps = Store.edges("DEPENDS_ON") |> Enum.group_by(& &1.from, & &1.to)
    children = Enum.group_by(raw, & &1.parent, & &1.key)
    now = Store.now()

    base = Map.new(raw, &{&1.key, &1})
    # Status is resolved in dependency order, so memoise as we go.
    {statuses, _} =
      Enum.reduce(raw, {%{}, MapSet.new()}, fn t, {memo, seen} ->
        {_, memo} = status(t.key, base, claims, deps, children, now, memo, seen)
        {memo, seen}
      end)

    Enum.map(raw, fn t ->
      claim = claims[t.key]

      t
      |> Map.put(:status, statuses[t.key])
      |> Map.put(:claim, claim)
      |> Map.put(:depends_on, deps[t.key] || [])
      |> Map.put(:subtasks, children[t.key] || [])
      |> Map.put(:attempts, (claim && claim.attempts) || 0)
    end)
  end

  @doc "One task with its derived fields, or nil."
  @spec task(String.t()) :: map() | nil
  def task(key), do: Enum.find(tasks(), &(&1.key == key))

  @doc "Tasks in a given status."
  @spec by_status(String.t()) :: [map()]
  def by_status(status), do: Enum.filter(tasks(), &(&1.status == status))

  defp status(key, base, claims, deps, children, now, memo, seen) do
    cond do
      Map.has_key?(memo, key) ->
        {memo[key], memo}

      MapSet.member?(seen, key) ->
        # A dependency cycle: call it blocked rather than recurse forever.
        {"blocked", memo}

      not Map.has_key?(base, key) ->
        # A dependency on a task this replica has not received yet.
        {"blocked", memo}

      true ->
        seen = MapSet.put(seen, key)
        claim = claims[key]

        {s, memo} =
          case claim && Claims.state(claim, now) do
            "done" ->
              {"done", memo}

            "split" ->
              {kid_states, memo} =
                Enum.map_reduce(children[key] || [], memo, fn c, m ->
                  status(c, base, claims, deps, children, now, m, seen)
                end)

              {if(kid_states != [] and Enum.all?(kid_states, &(&1 == "done")),
                 do: "done",
                 else: "split"
               ), memo}

            "claimed" ->
              {"claimed", memo}

            state ->
              if state == "failed" and (claim.attempts || 0) >= @max_attempts do
                {"failed", memo}
              else
                {dep_states, memo} =
                  Enum.map_reduce(deps[key] || [], memo, fn d, m ->
                    status(d, base, claims, deps, children, now, m, seen)
                  end)

                {if(Enum.all?(dep_states, &(&1 == "done")), do: "open", else: "blocked"), memo}
              end
          end

        {s, Map.put(memo, key, s)}
    end
  end

  defp goal_of(task_key) do
    case Store.get(task_key) do
      %{"goal" => g} when g not in [nil, ""] -> g
      _ -> nil
    end
  end

  @doc "The maximum attempts before a failing task stays failed."
  def max_attempts, do: @max_attempts

  defp priority(p) when is_integer(p), do: p |> max(1) |> min(5)

  defp priority(p) when is_binary(p),
    do:
      p
      |> Integer.parse()
      |> then(fn
        {i, _} -> priority(i)
        _ -> 3
      end)

  defp priority(_), do: 3

  defp get(attrs, k, default), do: Map.get(attrs, k) || Map.get(attrs, to_string(k)) || default

  defp req!(attrs, k) do
    case get(attrs, k, nil) do
      v when is_binary(v) and v != "" -> v
      _ -> raise ArgumentError, "#{k} is required"
    end
  end
end
