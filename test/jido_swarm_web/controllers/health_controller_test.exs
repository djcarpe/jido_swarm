defmodule JidoSwarmWeb.HealthControllerTest do
  use JidoSwarmWeb.ConnCase, async: true

  test "GET /health is alive", %{conn: conn} do
    conn = get(conn, ~p"/health")

    assert json_response(conn, 200) == %{"status" => "ok"}
  end

  test "GET /health/ready reports what it checked", %{conn: conn} do
    conn = get(conn, ~p"/health/ready")

    body = json_response(conn, 200)
    assert body["status"] == "ready"
    assert is_map(body["checks"])
    assert Map.has_key?(body["checks"], "graph")
  end

  test "readiness does not depend on the model being reachable", %{conn: conn} do
    # An unreachable model degrades the swarm and is surfaced in the UI, but it
    # is not a reason for Kubernetes to pull the pod and hide that fact.
    conn = get(conn, ~p"/health/ready")

    refute Map.has_key?(json_response(conn, 200)["checks"], "model")
  end
end
