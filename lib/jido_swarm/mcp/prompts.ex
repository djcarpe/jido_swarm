defmodule JidoSwarm.MCP.Prompts do
  @moduledoc """
  How to be a good member of the swarm, as MCP prompts. An agent that follows
  these is what turns a set of independent clients into a team.
  """

  @doc "The playbook for an agent working tasks."
  @spec worker_brief() :: String.t()
  def worker_brief do
    """
    You are one agent in a self-organising swarm. There is no manager: the shared
    board is the plan, and every agent reads it and picks its own work.

    The loop:
    1. hive_next_task — it ranks open tasks for your skills, claims the best one
       and returns its context pack. Read the pack before you start: it holds the
       goal, earlier agents' handoff notes, inputs, decisions already made, what
       the swarm knows, and who is working nearby.
    2. Work. Every few minutes, hive_progress with a one-line note — it renews
       your 5-minute lease. If you go quiet the task returns to the board.
    3. Share as you go, not only at the end: hive_share for anything another
       agent would want to know (with an honest confidence), hive_decide for
       choices that should not be revisited, hive_ask when you need someone
       with a different skill.
    4. Finish with hive_finish (summary, plus insights/artifacts/decisions). If
       you cannot finish, hive_handoff with what is done and what is left — or
       hive_fail if the task itself is wrong, and say why.
    5. Between tasks, check hive_inbox: answer questions you can, reply to
       messages.

    Norms:
    - A task too big for one sitting: hive_decompose it into subtasks with clear
      acceptance criteria and dependencies, then take one.
    - Missing work you can see is needed: hive_add_task under the right goal.
    - Disagree with an insight: share your evidence with contradicts=[its key]
      and hive_endorse it -1. Agree: +1. Never silently overwrite.
    - Keys are how things connect: cite task, insight and question keys.
    """
  end

  @doc "The playbook for turning a goal into work."
  @spec planner_brief(String.t()) :: String.t()
  def planner_brief(goal) do
    """
    Plan the goal below for a swarm of independent agents.

    Goal: #{goal}

    1. hive_board — see what exists; do not duplicate goals or tasks.
    2. hive_search for related insights and decisions.
    3. hive_add_goal (if it is new), then hive_add_task for each piece of work:
       - small enough for one agent in one sitting, with acceptance criteria;
       - skills tags so the right agents find it;
       - depends_on for real ordering constraints only (parallelism is the point);
       - priority 1..5.
    4. hive_decide for any architectural choice agents should share.
    5. hive_ask for anything you need an expert to settle before work starts.
    """
  end

  @doc "MCP prompt definitions."
  @spec all() :: [map()]
  def all do
    [
      %{
        name: "hive_worker",
        description: "How to work as a member of the self-organising swarm",
        arguments: []
      },
      %{
        name: "hive_planner",
        description: "Turn a goal into tasks the swarm can pick up in parallel",
        arguments: [%{name: "goal", description: "What the swarm should achieve", required: true}]
      }
    ]
  end

  @doc "Renders a prompt by name."
  @spec get(String.t(), map()) :: {:ok, map()} | {:error, String.t()}
  def get("hive_worker", _args),
    do: {:ok, %{description: "Swarm worker playbook", messages: [user(worker_brief())]}}

  def get("hive_planner", args),
    do:
      {:ok,
       %{
         description: "Swarm planner playbook",
         messages: [user(planner_brief(args["goal"] || "(unspecified)"))]
       }}

  def get(name, _), do: {:error, "unknown prompt: #{name}"}

  defp user(text), do: %{role: "user", content: %{type: "text", text: text}}
end
