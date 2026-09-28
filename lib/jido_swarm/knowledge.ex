defmodule JidoSwarm.Knowledge do
  @moduledoc """
  The swarm's shared memory: a schema over `Jido.Context`.

  Every worker holds a full replica of this graph and writes into it; the mesh
  replicates by topic so a finding one worker made is a fact every other worker
  can traverse. This module is the only place that knows the shape, so the
  vocabulary stays consistent across workers that were written at different
  times by different prompts.

  ## Shape

  ```
  (:Repo)   ←[:ABOUT]────  (:Finding)
     ↑                         ↑
     │                    [:SUPPORTED_BY]
  [:FOR]                       │
     │                         │
  (:Proposal) ←[:IMPLEMENTS]─ (:Attempt)
  ```

  | Label | Meaning |
  |---|---|
  | `:Repo` | one of the target repositories |
  | `:Finding` | something a worker learned by reading code |
  | `:Proposal` | a feature a worker thinks is worth building |
  | `:Attempt` | an implementation of a proposal: branch, tests, PR |
  | `:ChatTurn` | a turn in the operator conversation |

  ## Topics

  | Topic | Carries |
  |---|---|
  | `knowledge.repos` | repository registration |
  | `knowledge.findings` | what workers learned |
  | `knowledge.proposals` | proposed features |
  | `knowledge.attempts` | implementation and PR state |
  | `context.chat` | the operator conversation |

  Every pod's graph subscribes to `knowledge.**`, `context.**` and `hive.**`,
  so it holds everything the swarm knows; `JidoSwarm.Hive.Feed` watches the
  same traffic and tells the console when something changed.
  """

  alias Jido.Context

  @graph_topics %{
    repos: "knowledge.repos",
    findings: "knowledge.findings",
    proposals: "knowledge.proposals",
    attempts: "knowledge.attempts",
    chat: "context.chat"
  }

  @doc "The topic a kind of fact is published on."
  @spec topic(atom()) :: String.t()
  def topic(kind), do: Map.fetch!(@graph_topics, kind)

  @doc "Every topic the swarm uses."
  @spec topics() :: [String.t()]
  def topics, do: Map.values(@graph_topics)

  # ===========================================================================
  # Repos
  # ===========================================================================

  @doc "Registers a target repository."
  @spec put_repo(atom(), map()) :: {:ok, term()} | {:error, term()}
  def put_repo(graph, repo) do
    Context.assert(
      graph,
      repo_key(repo.name),
      ["Repo"],
      %{
        "name" => repo.name,
        # Where the swarm's own clone lives, not the operator's checkout.
        "path" => JidoSwarm.Repos.path(repo),
        "url" => Map.get(repo, :url) || "",
        "default_branch" => Map.get(repo, :default_branch, "main"),
        "description" => Map.get(repo, :description, "")
      },
      topic: topic(:repos)
    )
  end

  @doc "Repositories the swarm knows about."
  @spec repos(atom()) :: [map()]
  def repos(graph) do
    query_maps(
      graph,
      "MATCH (r:Repo) RETURN r.name, r.path, r.url, r.default_branch, r.description",
      [:name, :path, :url, :default_branch, :description]
    )
  end

  # ===========================================================================
  # Findings
  # ===========================================================================

  @doc """
  Records something a worker learned while reading a repository.

  `kind` is a free-form tag — `"gap"`, `"pattern"`, `"risk"` — that lets a later
  query ask for one sort of observation without re-reading the code.
  """
  @spec add_finding(atom(), String.t(), map()) :: {:ok, term()} | {:error, term()}
  def add_finding(graph, repo_name, finding) do
    id = finding[:id] || new_id("finding")
    key = "finding:" <> id

    Context.commit(
      graph,
      [
        {:put_node, key, ["Finding"],
         %{
           "summary" => finding.summary,
           "detail" => Map.get(finding, :detail, ""),
           "kind" => Map.get(finding, :kind, "observation"),
           "worker" => Map.get(finding, :worker, "unknown"),
           "at" => now()
         }},
        {:put_edge, key, "ABOUT", repo_key(repo_name), %{}}
      ],
      topic: topic(:findings)
    )
  end

  @doc "Findings about a repository, newest first."
  @spec findings(atom(), String.t() | :all) :: [map()]
  def findings(graph, repo_name \\ :all)

  def findings(graph, :all) do
    query_maps(
      graph,
      "MATCH (f:Finding) RETURN f._key, f.summary, f.kind, f.worker, f.at ORDER BY f.at DESC",
      [:key, :summary, :kind, :worker, :at]
    )
  end

  def findings(graph, repo_name) do
    query_maps(
      graph,
      """
      MATCH (f:Finding)-[:ABOUT]->(r:Repo #{key_match(repo_key(repo_name))})
      RETURN f._key, f.summary, f.kind, f.worker, f.at ORDER BY f.at DESC
      """,
      [:key, :summary, :kind, :worker, :at]
    )
  end

  # ===========================================================================
  # Proposals
  # ===========================================================================

  @doc """
  Records a proposed feature, linked to its repository and to the findings that
  motivated it.
  """
  @spec add_proposal(atom(), String.t(), map()) :: {:ok, String.t()} | {:error, term()}
  def add_proposal(graph, repo_name, proposal) do
    id = proposal[:id] || new_id("proposal")
    key = "proposal:" <> id

    support_edges =
      proposal
      |> Map.get(:supported_by, [])
      |> Enum.map(fn finding_key -> {:put_edge, key, "SUPPORTED_BY", finding_key, %{}} end)

    ops =
      [
        {:put_node, key, ["Proposal"],
         %{
           "title" => proposal.title,
           "rationale" => Map.get(proposal, :rationale, ""),
           "sketch" => Map.get(proposal, :sketch, ""),
           "status" => Map.get(proposal, :status, "proposed"),
           "repo" => repo_name,
           "worker" => Map.get(proposal, :worker, "unknown"),
           "at" => now()
         }},
        {:put_edge, key, "FOR", repo_key(repo_name), %{}}
      ] ++ support_edges

    case Context.commit(graph, ops, topic: topic(:proposals)) do
      {:ok, _delta} -> {:ok, key}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Moves a proposal to a new status."
  @spec set_proposal_status(atom(), String.t(), String.t()) :: {:ok, term()} | {:error, term()}
  def set_proposal_status(graph, proposal_key, status) do
    Context.assert(graph, proposal_key, ["Proposal"], %{"status" => status},
      topic: topic(:proposals)
    )
  end

  @doc "Proposals, newest first, optionally filtered by status."
  @spec proposals(atom(), String.t() | :all) :: [map()]
  def proposals(graph, status \\ :all)

  def proposals(graph, :all) do
    query_maps(
      graph,
      """
      MATCH (p:Proposal)
      RETURN p._key, p.title, p.rationale, p.status, p.repo, p.worker, p.at
      ORDER BY p.at DESC
      """,
      [:key, :title, :rationale, :status, :repo, :worker, :at]
    )
  end

  def proposals(graph, status) do
    query_maps(
      graph,
      """
      MATCH (p:Proposal) WHERE p.status = #{encode(status)}
      RETURN p._key, p.title, p.rationale, p.status, p.repo, p.worker, p.at
      ORDER BY p.at DESC
      """,
      [:key, :title, :rationale, :status, :repo, :worker, :at]
    )
  end

  @doc "One proposal by key."
  @spec proposal(atom(), String.t()) :: map() | nil
  def proposal(graph, proposal_key) do
    query_maps(
      graph,
      """
      MATCH (p:Proposal #{key_match(proposal_key)})
      RETURN p._key, p.title, p.rationale, p.sketch, p.status, p.repo, p.worker, p.at
      """,
      [:key, :title, :rationale, :sketch, :status, :repo, :worker, :at]
    )
    |> List.first()
  end

  # ===========================================================================
  # Attempts
  # ===========================================================================

  @doc "Records an implementation attempt against a proposal."
  @spec add_attempt(atom(), String.t(), map()) :: {:ok, String.t()} | {:error, term()}
  def add_attempt(graph, proposal_key, attempt) do
    id = attempt[:id] || new_id("attempt")
    key = "attempt:" <> id

    ops = [
      {:put_node, key, ["Attempt"], attempt_props(attempt)},
      {:put_edge, key, "IMPLEMENTS", proposal_key, %{}}
    ]

    case Context.commit(graph, ops, topic: topic(:attempts)) do
      {:ok, _delta} -> {:ok, key}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Updates an attempt in place — status, branch, test output, PR url."
  @spec update_attempt(atom(), String.t(), map()) :: {:ok, term()} | {:error, term()}
  def update_attempt(graph, attempt_key, attempt) do
    Context.assert(graph, attempt_key, ["Attempt"], attempt_props(attempt),
      topic: topic(:attempts)
    )
  end

  defp attempt_props(attempt) do
    %{
      "status" => Map.get(attempt, :status, "started"),
      "branch" => Map.get(attempt, :branch, ""),
      "repo" => Map.get(attempt, :repo, ""),
      "tests" => Map.get(attempt, :tests, ""),
      "pr_url" => Map.get(attempt, :pr_url, ""),
      "note" => Map.get(attempt, :note, ""),
      "worker" => Map.get(attempt, :worker, "unknown"),
      "at" => now()
    }
  end

  @doc "Attempts, newest first."
  @spec attempts(atom()) :: [map()]
  def attempts(graph) do
    query_maps(
      graph,
      """
      MATCH (a:Attempt) RETURN a._key, a.status, a.branch, a.repo, a.pr_url, a.note, a.at
      ORDER BY a.at DESC
      """,
      [:key, :status, :branch, :repo, :pr_url, :note, :at]
    )
  end

  # ===========================================================================
  # Chat
  # ===========================================================================

  @doc "Appends a turn to the operator conversation."
  @spec add_chat_turn(atom(), map()) :: {:ok, term()} | {:error, term()}
  def add_chat_turn(graph, turn) do
    id = turn[:id] || new_id("turn")

    Context.assert(
      graph,
      "turn:" <> id,
      ["ChatTurn"],
      %{
        "role" => to_string(turn.role),
        "body" => turn.body,
        "worker" => Map.get(turn, :worker, ""),
        "at" => Map.get(turn, :at, now())
      },
      topic: topic(:chat)
    )
  end

  @doc "The conversation, oldest first."
  @spec chat_turns(atom(), pos_integer()) :: [map()]
  def chat_turns(graph, limit \\ 200) do
    graph
    |> query_maps(
      "MATCH (t:ChatTurn) RETURN t._key, t.role, t.body, t.worker, t.at ORDER BY t.at DESC LIMIT #{limit}",
      [:key, :role, :body, :worker, :at]
    )
    |> Enum.reverse()
  end

  # ===========================================================================
  # Summary
  # ===========================================================================

  @doc """
  Counts for the dashboard, in one pass per label.

  `Jido.Context.stats/2` gives whole-graph totals; this gives the swarm's own
  vocabulary, which is what an operator actually wants to see.
  """
  @spec summary(atom()) :: map()
  def summary(graph) do
    %{
      repos: count(graph, "Repo"),
      findings: count(graph, "Finding"),
      proposals: count(graph, "Proposal"),
      attempts: count(graph, "Attempt"),
      graph: graph_stats(graph)
    }
  end

  defp count(graph, label) do
    case Context.query(graph, "MATCH (n:#{label}) RETURN count(n)") do
      # Glider returns zero rows for a count over zero matches, rather than a
      # row holding 0.
      {:ok, %{rows: [[n] | _]}} when is_integer(n) -> n
      _ -> 0
    end
  end

  defp graph_stats(graph) do
    case Context.stats(graph) do
      {:ok, stats} -> stats
      _ -> %{}
    end
  end

  # ===========================================================================
  # Helpers
  # ===========================================================================

  @doc "The graph key for a repository."
  @spec repo_key(String.t()) :: String.t()
  def repo_key(name), do: "repo:" <> name

  defp query_maps(graph, cypher, fields) do
    case Context.query(graph, cypher) do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn row -> fields |> Enum.zip(row) |> Map.new() end)

      {:error, _reason} ->
        []
    end
  end

  defp key_match(key), do: "{_key: #{encode(key)}}"

  defp encode(value), do: Jido.Context.Cypher.encode_value(value)

  defp now, do: System.system_time(:millisecond)

  defp new_id(prefix) do
    prefix <> "_" <> (:crypto.strong_rand_bytes(8) |> Base.encode32(case: :lower, padding: false))
  end
end
