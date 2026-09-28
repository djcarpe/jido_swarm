defmodule Mix.Tasks.Hive.Mcp do
  @shortdoc "Bridges an MCP stdio client to a running swarm's /mcp endpoint"

  @moduledoc """
  Speaks MCP over stdio and forwards every message to a swarm's HTTP endpoint,
  for clients that launch servers as subprocesses.

      $ mix hive.mcp                                   # http://localhost:4000/mcp
      $ mix hive.mcp --url https://swarm.example/mcp --token $SWARM_MCP_TOKEN

  With Claude Code:

      claude mcp add hive -- mix hive.mcp --url http://localhost:4000/mcp

  (Clients that speak Streamable HTTP can skip the bridge:
  `claude mcp add --transport http hive http://localhost:4000/mcp`.)

  The bridge holds no state beyond the session id the server issued, so the
  swarm — not this process — is where membership and claims live. Nothing but
  JSON-RPC is written to stdout; diagnostics go to stderr.
  """

  use Mix.Task

  @impl Mix.Task
  def run(argv) do
    {opts, _, _} = OptionParser.parse(argv, strict: [url: :string, token: :string])
    url = opts[:url] || System.get_env("SWARM_MCP_URL", "http://localhost:4000/mcp")
    token = opts[:token] || System.get_env("SWARM_MCP_TOKEN")

    {:ok, _} = Application.ensure_all_started(:req)
    loop(url, token, nil)
  end

  defp loop(url, token, session) do
    case IO.read(:stdio, :line) do
      :eof ->
        :ok

      {:error, reason} ->
        IO.puts(:stderr, "hive.mcp: stdin error #{inspect(reason)}")

      line ->
        case String.trim(line) do
          "" -> loop(url, token, session)
          body -> loop(url, token, forward(url, token, session, body))
        end
    end
  end

  defp forward(url, token, session, body) do
    headers =
      [{"content-type", "application/json"}, {"accept", "application/json, text/event-stream"}] ++
        if(session, do: [{"mcp-session-id", session}], else: []) ++
        if(token, do: [{"authorization", "Bearer " <> token}], else: [])

    case Req.post(url,
           body: body,
           headers: headers,
           decode_body: false,
           retry: false,
           receive_timeout: 120_000
         ) do
      {:ok, %{status: status, body: resp, headers: h}} when status in 200..299 ->
        if resp not in [nil, ""], do: IO.write(:stdio, IO.iodata_to_binary([resp, "\n"]))
        List.first(Map.get(h, "mcp-session-id", [])) || session

      {:ok, %{status: status, body: resp}} ->
        IO.puts(:stderr, "hive.mcp: HTTP #{status}: #{resp}")
        reply_error(body, "swarm returned HTTP #{status}")
        session

      {:error, e} ->
        IO.puts(:stderr, "hive.mcp: #{Exception.message(e)}")
        reply_error(body, "swarm unreachable at #{url}")
        session
    end
  end

  # A request (not a notification) must get an answer, or the client hangs.
  defp reply_error(body, message) do
    with {:ok, %{"id" => id}} when not is_nil(id) <- Jason.decode(body) do
      err = %{
        "jsonrpc" => "2.0",
        "id" => id,
        "error" => %{"code" => -32000, "message" => message}
      }

      IO.write(:stdio, Jason.encode!(err) <> "\n")
    end
  end
end
