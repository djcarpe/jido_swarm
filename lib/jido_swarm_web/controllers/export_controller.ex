defmodule JidoSwarmWeb.ExportController do
  @moduledoc """
  Downloads of this replica's graph as JSON Lines.

  `GET /export/:scope` for a scope `JidoSwarm.Knowledge.Export` knows —
  `graph`, `knowledge`, `context` or `hive`. The file is produced by the
  graph process in one call and sent as an attachment; there is nothing to
  stream, because Glider hands the export back whole.
  """

  use JidoSwarmWeb, :controller

  alias JidoSwarm.Knowledge.Export

  def show(conn, %{"scope" => name}) do
    with scope when not is_nil(scope) <- Export.scope(name),
         true <- JidoSwarm.graph_available?() || {:error, :graph_unavailable},
         {:ok, jsonl, counts} <- Export.jsonl(scope) do
      origin = Jido.Context.Graph.origin(JidoSwarm.graph())

      conn
      |> put_resp_header("x-swarm-nodes", Integer.to_string(counts.nodes))
      |> put_resp_header("x-swarm-edges", Integer.to_string(counts.edges))
      |> send_download({:binary, IO.iodata_to_binary(jsonl)},
        filename: Export.filename(scope, origin),
        content_type: "application/x-ndjson"
      )
    else
      nil ->
        conn
        |> put_status(:not_found)
        |> text("No such export. Try graph, knowledge, context or hive.")

      {:error, :graph_unavailable} ->
        conn
        |> put_status(:service_unavailable)
        |> text("The graph engine is not available on this node.")

      {:error, reason} ->
        conn |> put_status(:internal_server_error) |> text("Export failed: #{inspect(reason)}")
    end
  end
end
