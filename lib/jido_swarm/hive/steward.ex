defmodule JidoSwarm.Hive.Steward do
  @moduledoc """
  Keeps the swarm busy without an operator.

  Left alone, the swarm does nothing: a survey cycle is a button, and the
  Hive's agents poll a board that only fills when someone adds to it. The
  steward is the standing order. On every tick it makes sure the board holds
  one standing goal and, for each repository, one live task under it — and
  when the swarm finishes a repository's task, the next tick opens a fresh
  round for it. What the agents learn along the way lands in the graph as
  insights, questions, decisions and notes, which is where a shared memory's
  volume comes from.

  ## Why deterministic keys

  Every pod runs a steward, and two pods that both decide the board is empty
  would each add a goal. The goal is written under one fixed key and each
  round's task under a key built from the repository and the round, so two
  pods writing the same thing converge on one entity by last-writer-wins
  instead of doubling the board. No leader election, no lock.

  ## Configuration

  * `SWARM_STANDING_GOAL` — the goal's title, or `off` to disable the steward.
  * `SWARM_CYCLE_EVERY_MS` — how often to look at the board (default 30 min).
  """

  use GenServer

  require Logger

  alias JidoSwarm.Hive.Board
  alias JidoSwarm.Hive.Store

  @goal_key "goal:standing"
  @first_tick_ms 5_000
  @live_statuses ~w(open claimed blocked split)

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "The standing goal's key, so others can recognise its tasks."
  @spec goal_key() :: String.t()
  def goal_key, do: @goal_key

  @doc """
  Makes the board hold the standing goal and one live task per repository.

  Returns the keys of the tasks it added, `[]` when the board already had
  work for every repository. Safe to call from any pod at any time.
  """
  @spec seed(keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def seed(opts \\ []) do
    title = Keyword.get(opts, :title, goal_title())
    repos = Keyword.get(opts, :repos, JidoSwarm.Repos.all())

    with {:ok, _} <-
           Board.add_goal(%{
             key: @goal_key,
             title: title,
             description:
               "The swarm's standing order. Each repository keeps one live task under this " <>
                 "goal; finish it by recording what you learned, and the steward opens the next round.",
             priority: 3,
             created_by: "steward"
           }) do
      live = live_by_repo()

      repos
      |> Enum.reject(&Map.has_key?(live, &1.name))
      |> Enum.reduce_while({:ok, []}, fn repo, {:ok, acc} ->
        case Board.add_task(task_for(repo, next_round(repo.name))) do
          {:ok, key} -> {:cont, {:ok, [key | acc]}}
          {:error, _} = error -> {:halt, error}
        end
      end)
    end
  end

  @doc "Runs a tick now: seed the board, and queue a survey cycle if it is this pod's turn."
  @spec tick(GenServer.server()) :: :ok
  def tick(server \\ __MODULE__), do: GenServer.call(server, :tick, 30_000)

  @impl true
  def init(opts) do
    if enabled?() do
      Process.send_after(self(), :tick, Keyword.get(opts, :first_tick_ms, @first_tick_ms))
      {:ok, %{every: Keyword.get(opts, :every_ms, every_ms())}}
    else
      Logger.info("hive steward: off (SWARM_STANDING_GOAL=off)")
      :ignore
    end
  end

  @impl true
  def handle_call(:tick, _from, state) do
    run()
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:tick, state) do
    run()
    Process.send_after(self(), :tick, state.every)
    {:noreply, state}
  end

  defp run do
    case seed() do
      {:ok, []} ->
        :ok

      {:ok, keys} ->
        Logger.info("hive steward: opened #{length(keys)} task(s): #{Enum.join(keys, ", ")}")

      {:error, reason} ->
        Logger.warning("hive steward: could not seed the board: #{inspect(reason)}")
    end
  rescue
    e -> Logger.warning("hive steward: tick failed: #{Exception.message(e)}")
  catch
    :exit, reason -> Logger.warning("hive steward: tick failed: #{inspect(reason)}")
  end

  # The live standing tasks, by repository: a repository with one does not
  # get another until it is done or failed.
  defp live_by_repo do
    Board.tasks()
    |> Enum.filter(&(&1.goal == @goal_key and &1.status in @live_statuses))
    |> Enum.flat_map(fn t ->
      case repo_of(t.key) do
        nil -> []
        repo -> [{repo, t}]
      end
    end)
    |> Map.new()
  end

  # Rounds count every standing task ever opened for a repository, done or not.
  defp next_round(repo) do
    Store.all("HiveTask", ~w(goal))
    |> Enum.count(&(&1.goal == @goal_key and repo_of(&1.key) == repo))
    |> Kernel.+(1)
  end

  defp repo_of("task:standing:" <> rest) do
    case String.split(rest, ":") do
      [repo, _round] -> repo
      _ -> nil
    end
  end

  defp repo_of(_), do: nil

  defp task_for(repo, round) do
    lang =
      if String.contains?(Map.get(repo, :test_command) || "", "cargo"), do: "rust", else: "elixir"

    %{
      key: "task:standing:#{repo.name}:#{round}",
      goal: @goal_key,
      title: "Survey #{repo.name} (round #{round}) and record what you learn",
      detail:
        "Read #{repo.name} at #{Map.get(repo, :path) || repo.url} — its README, its main modules, its tests. " <>
          "Share every fact worth keeping as an insight about repo:#{repo.name} (kind fact, " <>
          "finding, risk or idea, with your confidence). Ask a question when something is " <>
          "unclear. Then split off one concrete improvement as a subtask a later agent can " <>
          "implement, with acceptance criteria, and finish this task with a summary.",
      acceptance:
        "At least five insights shared about repo:#{repo.name}, one improvement proposed as " <>
          "a subtask, and a summary on finish.",
      priority: 3,
      skills: ["research", lang],
      created_by: "steward"
    }
  end

  defp enabled?, do: String.downcase(goal_title()) not in ["off", "false", "0", ""]

  defp goal_title do
    Application.get_env(
      :jido_swarm,
      :standing_goal,
      "Keep learning the repositories: survey them, propose improvements, implement the good ones"
    )
  end

  defp every_ms, do: Application.get_env(:jido_swarm, :cycle_every_ms, 1_800_000)
end
