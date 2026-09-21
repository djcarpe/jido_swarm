defmodule JidoSwarmWeb.HealthController do
  @moduledoc """
  Liveness and readiness for the container runtime.

  Excluded from `force_ssl`, because a kubelet probe reaches the pod directly
  over plain HTTP with no `x-forwarded-proto` header. Without the exclusion it
  gets a 301 — which counts as success, so the pod looks healthy for the wrong
  reason and would go on looking healthy if the app were broken.
  """

  use JidoSwarmWeb, :controller

  @doc "Alive: the endpoint is serving."
  def show(conn, _params) do
    json(conn, %{status: "ok"})
  end

  @doc """
  Ready: the pieces the swarm needs are actually up.

  The model is deliberately *not* part of readiness — an unreachable model is
  reported in the UI and degrades the swarm, but it is not a reason for
  Kubernetes to take the pod out of rotation and hide that fact.
  """
  def ready(conn, _params) do
    checks = %{
      graph: JidoSwarm.graph_available?(),
      pool: JidoSwarm.Swarm.worker_count() >= 0
    }

    status = if Enum.all?(Map.values(checks)), do: 200, else: 503

    conn
    |> put_status(status)
    |> json(%{status: if(status == 200, do: "ready", else: "degraded"), checks: checks})
  end
end
