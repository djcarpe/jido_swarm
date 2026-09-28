defmodule JidoSwarmWeb.ExportControllerTest do
  use JidoSwarmWeb.ConnCase, async: false

  alias Jido.Context

  setup do
    tag = System.unique_integer([:positive])
    graph = JidoSwarm.graph()

    {:ok, _} =
      Context.commit(
        graph,
        [
          {:put_node, "export:task:#{tag}", ["ExportThing"], %{"title" => "hive #{tag}"}},
          {:put_edge, "export:task:#{tag}", "ABOUT", "repo:jido", %{}}
        ],
        topic: "hive.board"
      )

    {:ok, _} =
      Context.assert(graph, "export:finding:#{tag}", ["Finding"], %{"text" => "knowledge #{tag}"},
        topic: "knowledge.findings"
      )

    {:ok, tag: tag}
  end

  defp lines(body), do: body |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)

  test "the whole graph downloads as JSON Lines with the mesh stamps", %{conn: conn, tag: tag} do
    conn = get(conn, ~p"/export/graph")

    assert response_content_type(conn, :"x-ndjson") =~ "application/x-ndjson"
    [disposition] = get_resp_header(conn, "content-disposition")
    assert disposition =~ ~r/attachment; filename="swarm-.+-graph-\d{8}-\d{6}\.jsonl"/

    entries = lines(conn.resp_body)
    keys = for %{"type" => "node", "props" => %{"_key" => key}} <- entries, do: key
    assert "export:task:#{tag}" in keys and "export:finding:#{tag}" in keys

    task = Enum.find(entries, &(&1["props"]["_key"] == "export:task:#{tag}"))
    assert task["labels"] == ["Ctx", "ExportThing"]
    assert task["props"]["_topic"] == "hive.board" and is_binary(task["props"]["_origin"])

    [nodes] = get_resp_header(conn, "x-swarm-nodes")
    assert String.to_integer(nodes) == Enum.count(entries, &(&1["type"] == "node"))
  end

  test "a scope keeps its topic's entities and only the edges between them", %{
    conn: conn,
    tag: tag
  } do
    entries = lines(get(conn, ~p"/export/hive").resp_body)
    keys = for %{"type" => "node", "props" => %{"_key" => key}} <- entries, do: key

    assert "export:task:#{tag}" in keys
    refute "export:finding:#{tag}" in keys

    assert Enum.all?(
             entries,
             &(&1["type"] == "edge" or String.starts_with?(&1["props"]["_topic"], "hive."))
           )

    # The task's edge to a knowledge node crosses the scope, so it is dropped.
    ids = MapSet.new(entries, & &1["id"])

    for %{"type" => "edge", "from" => from, "to" => to} <- entries do
      assert MapSet.member?(ids, from) and MapSet.member?(ids, to)
    end

    knowledge = lines(get(conn, ~p"/export/knowledge").resp_body)
    assert Enum.any?(knowledge, &(&1["props"]["_key"] == "export:finding:#{tag}"))
    refute Enum.any?(knowledge, &(&1["props"]["_key"] == "export:task:#{tag}"))
  end

  test "an unknown scope is a 404", %{conn: conn} do
    assert get(conn, ~p"/export/everything").status == 404
  end
end
