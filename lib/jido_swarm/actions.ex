defmodule JidoSwarm.Actions do
  @moduledoc """
  Shared plumbing for the swarm's actions.

  The actions themselves live in `JidoSwarm.Actions.Survey`,
  `.Propose`, `.Implement` and `.Chat`; this holds the one thing they all need.
  """

  @doc """
  Runs an action body and turns its outcome into data.

  Jido reports a failed instruction by emitting an error directive. The caller
  of `Jido.AgentServer.call/3` still receives `{:ok, agent}`, and on failure
  nothing is merged into agent state — so a worker cannot tell success from
  failure by the return value alone.

  Every action therefore reports through here, and success *and* handled failure
  both merge a result. The `:job_id` is what makes it trustworthy: agent state
  persists between jobs, so a stale `outcome: :ok` from the previous job would
  otherwise look like this one succeeding. The worker accepts an outcome only
  when the job id matches the job it dispatched.

  Genuine crashes still crash. This converts *expected* failure — a model
  returning nonsense, a repository that will not clone — into a recorded fact.
  """
  @spec outcome(map(), (-> {:ok, map()} | {:error, term()})) :: {:ok, map()}
  def outcome(params, fun) do
    base = %{
      job_id: Map.get(params, :job_id, ""),
      finished_at: System.system_time(:millisecond)
    }

    case fun.() do
      {:ok, result} when is_map(result) ->
        {:ok, result |> Map.merge(base) |> Map.put(:outcome, :ok)}

      {:error, reason} ->
        {:ok, Map.merge(base, %{outcome: :error, error: inspect(reason)})}
    end
  end
end
