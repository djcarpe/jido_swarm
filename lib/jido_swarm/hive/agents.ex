defmodule JidoSwarm.Hive.Agents do
  @moduledoc """
  Who is in the swarm: presence, skills, and a track record.

  An agent is anything that works the board — a Jido worker in this VM, a
  worker on another pod, a Claude Code session connected over MCP, a person.
  Each writes only its own `agent:<id>` node, so presence never conflicts.

  Presence is soft state. An agent is **active** while its last heartbeat is
  younger than `stale_after` (default two minutes); after that the swarm treats
  it as gone and its leases run out on their own. Nothing has to notice a
  crash for the work to come back.
  """

  alias JidoSwarm.Hive.Store

  @stale_after 120_000

  @type t :: %{
          id: String.t(),
          name: String.t(),
          kind: String.t(),
          skills: [String.t()],
          model: String.t(),
          status: String.t(),
          last_seen: integer(),
          joined: integer()
        }

  @doc """
  Joins the swarm, or refreshes an existing membership.

  * `:id` — keep a stable id across reconnects; a fresh one is made otherwise.
  * `:name`, `:kind` (`"worker"`, `"mcp"`, `"human"`), `:skills`, `:model`.
  """
  @spec join(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def join(opts) do
    opts = Map.new(opts)
    id = opts[:id] || Store.new_id("agent")
    now = Store.now()
    previous = get(id)

    agent = %{
      id: id,
      name: opts[:name] || id,
      kind: to_string(opts[:kind] || "mcp"),
      skills: normalize_skills(opts[:skills] || (previous && previous.skills) || []),
      model: to_string(opts[:model] || ""),
      status: "active",
      last_seen: now,
      joined: (previous && previous.joined) || now
    }

    with :ok <- write(agent), do: {:ok, agent}
  end

  @doc "Records that an agent is alive, optionally with a status line."
  @spec heartbeat(String.t(), String.t() | nil) :: :ok | {:error, :unknown_agent}
  def heartbeat(id, status \\ nil) do
    case get(id) do
      nil -> {:error, :unknown_agent}
      agent -> write(%{agent | last_seen: Store.now(), status: status || agent.status})
    end
  end

  @doc "Leaves the swarm. Leases it holds run out; nothing else is undone."
  @spec leave(String.t()) :: :ok
  def leave(id) do
    case get(id) do
      nil -> :ok
      agent -> write(%{agent | status: "left", last_seen: Store.now()})
    end
  end

  @doc "One agent, or nil."
  @spec get(String.t()) :: t() | nil
  def get(id) do
    case Store.get(key(id)) do
      nil -> nil
      props -> from_props(props)
    end
  end

  @doc "Every agent that has ever joined."
  @spec all() :: [t()]
  def all do
    Store.all("HiveAgent", ~w(id name kind skills model status last_seen joined))
    |> Enum.map(&from_row/1)
  end

  @doc "Agents seen within `stale_after` that have not left."
  @spec active(integer()) :: [t()]
  def active(stale_after \\ @stale_after) do
    cutoff = Store.now() - stale_after
    Enum.filter(all(), &(&1.status != "left" and &1.last_seen >= cutoff))
  end

  @doc "Is the agent present?"
  @spec active?(String.t()) :: boolean()
  def active?(id) do
    case get(id) do
      nil -> false
      a -> a.status != "left" and a.last_seen >= Store.now() - @stale_after
    end
  end

  @doc "The graph key of an agent."
  @spec key(String.t()) :: String.t()
  def key(id), do: "agent:" <> id

  @doc "Lower-cased, trimmed, de-duplicated skill tags."
  @spec normalize_skills([term()] | String.t()) :: [String.t()]
  def normalize_skills(skills) when is_binary(skills),
    do: normalize_skills(String.split(skills, ","))

  def normalize_skills(skills) when is_list(skills) do
    skills
    |> Enum.map(&(&1 |> to_string() |> String.trim() |> String.downcase()))
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  def normalize_skills(_), do: []

  defp write(agent) do
    Store.put(key(agent.id), ["HiveAgent"], agent, :agents)
  end

  defp from_props(p) do
    %{
      id: p["id"],
      name: p["name"] || p["id"],
      kind: p["kind"] || "mcp",
      skills: p["skills"] || [],
      model: p["model"] || "",
      status: p["status"] || "active",
      last_seen: p["last_seen"] || 0,
      joined: p["joined"] || 0
    }
  end

  defp from_row(r) do
    %{
      id: r.id,
      name: r.name || r.id,
      kind: r.kind || "mcp",
      skills: r.skills || [],
      model: r.model || "",
      status: r.status || "active",
      last_seen: r.last_seen || 0,
      joined: r.joined || 0
    }
  end
end
