defmodule JidoSwarmWeb.MCPController do
  @moduledoc """
  MCP's Streamable HTTP transport for `JidoSwarm.MCP`.

  * `POST /mcp` — one JSON-RPC message or a batch; answered with
    `application/json` (202 with no body when it was only notifications).
    `initialize` returns a new `Mcp-Session-Id`, which later requests echo.
  * `GET /mcp` — 405: the server does not open a server-to-client stream.
  * `DELETE /mcp` — ends the session.

  With `SWARM_MCP_TOKEN` set, every request needs `Authorization: Bearer <token>`.
  """

  use JidoSwarmWeb, :controller

  alias JidoSwarm.MCP

  plug :authorize

  def post(conn, params) do
    message = Map.get(params, "_json", params)
    session = get_req_header(conn, "mcp-session-id") |> List.first()

    session =
      if initialize?(message) or is_nil(session), do: MCP.new_session(), else: session

    conn = put_resp_header(conn, "mcp-session-id", session)

    case MCP.handle(message, session) do
      nil -> send_resp(conn, 202, "")
      response -> json(conn, response)
    end
  end

  def get(conn, _params) do
    conn |> put_resp_header("allow", "POST, DELETE") |> send_resp(405, "")
  end

  def delete(conn, _params) do
    case get_req_header(conn, "mcp-session-id") do
      [session | _] -> MCP.end_session(session)
      [] -> :ok
    end

    send_resp(conn, 204, "")
  end

  defp initialize?(%{"method" => "initialize"}), do: true
  defp initialize?(batch) when is_list(batch), do: Enum.any?(batch, &initialize?/1)
  defp initialize?(_), do: false

  defp authorize(conn, _opts) do
    case Application.get_env(:jido_swarm, :mcp_token) do
      token when token in [nil, ""] ->
        conn

      token ->
        expected = "Bearer " <> token

        case get_req_header(conn, "authorization") do
          [^expected] ->
            conn

          _ ->
            conn
            |> put_status(401)
            |> json(%{
              "jsonrpc" => "2.0",
              "id" => nil,
              "error" => %{"code" => -32001, "message" => "unauthorized"}
            })
            |> halt()
        end
    end
  end
end
