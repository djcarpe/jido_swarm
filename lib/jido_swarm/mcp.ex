defmodule JidoSwarm.MCP do
  @moduledoc """
  A Model Context Protocol server for the Hive: lets any MCP client — Claude
  Code, Claude Desktop, another agent framework — join the swarm as a peer of
  the in-VM Jido workers.

  JSON-RPC 2.0 over Streamable HTTP at `POST /mcp` (`JidoSwarmWeb.MCPController`),
  answering with `application/json`; `mix hive.mcp` bridges it to stdio for
  clients that only speak that.

      claude mcp add --transport http hive http://localhost:4000/mcp
      claude mcp add hive -- mix hive.mcp --url http://localhost:4000/mcp

  | Capability | What |
  |---|---|
  | tools | the `hive_*` tools in `JidoSwarm.MCP.Tools` |
  | resources | `hive://board` (the digest), `hive://task/<key>` (a context pack) |
  | prompts | `hive_worker`, `hive_planner` |

  **Sessions.** `initialize` issues an `Mcp-Session-Id`; `hive_join` binds the
  session to an agent, so later calls are attributed without repeating
  `agent_id`. Sessions live in ETS and are soft state: a lost session costs a
  `hive_join`, nothing more.

  **Auth.** With `SWARM_MCP_TOKEN` set, requests need
  `Authorization: Bearer <token>`. Without it the endpoint is open — fine on
  localhost, not on a network.
  """

  alias JidoSwarm.MCP.Prompts
  alias JidoSwarm.MCP.Tools

  @versions ~w(2025-11-25 2025-06-18 2025-03-26 2024-11-05)
  @table :hive_mcp_sessions

  @doc "Creates the session table. Called at application start."
  @spec init() :: :ok
  def init do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    end

    :ok
  end

  @doc "A fresh session id."
  @spec new_session() :: String.t()
  def new_session do
    init()
    id = :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
    :ets.insert(@table, {id, nil, System.system_time(:millisecond)})
    id
  end

  @doc "Ends a session."
  @spec end_session(String.t()) :: :ok
  def end_session(id) do
    init()
    :ets.delete(@table, id)
    :ok
  end

  @doc """
  Handles one decoded JSON-RPC message (or a batch) for a session. Returns the
  response, or nil for notifications.
  """
  @spec handle(map() | [map()], String.t() | nil) :: map() | [map()] | nil
  def handle(batch, session) when is_list(batch) do
    case batch |> Enum.map(&handle(&1, session)) |> Enum.reject(&is_nil/1) do
      [] -> nil
      rs -> rs
    end
  end

  def handle(%{"jsonrpc" => "2.0", "method" => method} = msg, session) do
    id = Map.get(msg, "id")
    params = Map.get(msg, "params") || %{}

    result =
      try do
        dispatch(method, params, session)
      rescue
        e in ArgumentError -> {:error, -32602, Exception.message(e)}
        e -> {:error, -32603, "internal error: " <> Exception.message(e)}
      end

    cond do
      is_nil(id) ->
        nil

      match?({:ok, _}, result) ->
        %{"jsonrpc" => "2.0", "id" => id, "result" => elem(result, 1)}

      true ->
        {:error, code, message} = result
        %{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => code, "message" => message}}
    end
  end

  def handle(%{"id" => id}, _session),
    do: %{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => %{"code" => -32600, "message" => "invalid request"}
    }

  def handle(_, _), do: nil

  # ===========================================================================
  # Methods
  # ===========================================================================

  defp dispatch("initialize", params, _session) do
    asked = params["protocolVersion"]

    {:ok,
     %{
       "protocolVersion" => if(asked in @versions, do: asked, else: hd(@versions)),
       "capabilities" => %{
         "tools" => %{"listChanged" => false},
         "resources" => %{"listChanged" => false, "subscribe" => false},
         "prompts" => %{"listChanged" => false}
       },
       "serverInfo" => %{
         "name" => "jido-swarm-hive",
         "title" => "Jido Swarm Hive",
         "version" => version()
       },
       "instructions" =>
         "A self-organising swarm over a shared knowledge graph. Call hive_join first, then loop: " <>
           "hive_next_task → work (hive_progress, hive_share) → hive_finish. The hive_worker prompt has the full playbook."
     }}
  end

  defp dispatch("notifications/" <> _, _params, _session), do: {:ok, %{}}
  defp dispatch("ping", _params, _session), do: {:ok, %{}}

  defp dispatch("tools/list", _params, _session) do
    {:ok, %{"tools" => Enum.map(Tools.all(), &Map.drop(&1, [:handler]))}}
  end

  defp dispatch("tools/call", %{"name" => name} = params, session) do
    case Enum.find(Tools.all(), &(&1.name == name)) do
      nil ->
        {:error, -32602, "unknown tool: #{name}"}

      tool ->
        ctx = %{agent: session_agent(session), session: session, set_agent: &bind(session, &1)}

        case tool.handler.(params["arguments"] || %{}, ctx) do
          {:ok, data} ->
            data = jsonable(data)

            {:ok,
             %{
               "content" => [%{"type" => "text", "text" => render(data)}],
               "structuredContent" => data,
               "isError" => false
             }}

          {:error, message} ->
            # Tool errors are results the model should see and act on, not
            # protocol errors.
            {:ok,
             %{
               "content" => [%{"type" => "text", "text" => "Error: " <> to_string(message)}],
               "isError" => true
             }}
        end
    end
  end

  defp dispatch("resources/list", _params, _session) do
    open =
      JidoSwarm.Hive.tasks()
      |> Enum.filter(&(&1.status in ["open", "claimed"]))
      |> Enum.take(50)
      |> Enum.map(
        &%{
          "uri" => "hive://task/" <> &1.key,
          "name" => &1.title,
          "mimeType" => "text/markdown",
          "description" => "Context pack (#{&1.status})"
        }
      )

    {:ok,
     %{
       "resources" => [
         %{
           "uri" => "hive://board",
           "name" => "Board",
           "mimeType" => "application/json",
           "description" => "Goals, work in flight, open tasks and questions, active agents"
         }
         | open
       ]
     }}
  end

  defp dispatch("resources/read", %{"uri" => "hive://board" = uri}, _session) do
    {:ok,
     %{
       "contents" => [
         %{
           "uri" => uri,
           "mimeType" => "application/json",
           "text" => Jason.encode!(jsonable(JidoSwarm.Hive.digest()), pretty: true)
         }
       ]
     }}
  end

  defp dispatch("resources/read", %{"uri" => "hive://task/" <> key = uri}, session) do
    case JidoSwarm.Hive.context(key, agent: session_agent(session)) do
      {:ok, pack} ->
        {:ok,
         %{
           "contents" => [%{"uri" => uri, "mimeType" => "text/markdown", "text" => pack.markdown}]
         }}

      {:error, _} ->
        {:error, -32002, "resource not found: #{uri}"}
    end
  end

  defp dispatch("resources/read", %{"uri" => uri}, _),
    do: {:error, -32002, "resource not found: #{uri}"}

  defp dispatch("resources/templates/list", _, _),
    do:
      {:ok,
       %{
         "resourceTemplates" => [
           %{
             "uriTemplate" => "hive://task/{key}",
             "name" => "Task context pack",
             "mimeType" => "text/markdown"
           }
         ]
       }}

  defp dispatch("prompts/list", _params, _session), do: {:ok, %{"prompts" => Prompts.all()}}

  defp dispatch("prompts/get", %{"name" => name} = params, _session) do
    case Prompts.get(name, params["arguments"] || %{}) do
      {:ok, p} -> {:ok, p}
      {:error, m} -> {:error, -32602, m}
    end
  end

  defp dispatch(method, _params, _session), do: {:error, -32601, "method not found: #{method}"}

  # ===========================================================================
  # Sessions
  # ===========================================================================

  defp session_agent(nil), do: nil

  defp session_agent(session) do
    init()

    case :ets.lookup(@table, session) do
      [{_, agent, _}] -> agent
      [] -> nil
    end
  end

  defp bind(nil, _agent), do: :ok

  defp bind(session, agent) do
    init()
    :ets.insert(@table, {session, agent, System.system_time(:millisecond)})
    :ok
  end

  # ===========================================================================
  # Encoding
  # ===========================================================================

  defp render(data), do: Jason.encode!(data, pretty: true)

  # Terms JSON can carry: atoms become strings, tuples lists, structs maps.
  @doc false
  def jsonable(%_{} = s), do: s |> Map.from_struct() |> jsonable()
  def jsonable(m) when is_map(m), do: Map.new(m, fn {k, v} -> {to_string(k), jsonable(v)} end)
  def jsonable(l) when is_list(l), do: Enum.map(l, &jsonable/1)
  def jsonable(t) when is_tuple(t), do: t |> Tuple.to_list() |> jsonable()
  def jsonable(a) when is_atom(a) and a not in [nil, true, false], do: Atom.to_string(a)
  def jsonable(v), do: v

  defp version, do: to_string(Application.spec(:jido_swarm, :vsn) || "0.1.0")
end
