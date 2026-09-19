defmodule JidoSwarm do
  @moduledoc """
  An elastic swarm of Jido agents that share a knowledge graph and work on code.

  The swarm surveys three repositories — `jido`, `glider` and `glider_ex` —
  records what it learns in a graph every member can read, proposes features
  that follow from those findings, and implements the ones it is asked to.

  ## The parts

  | Module | Role |
  |---|---|
  | `JidoSwarm.Swarm` | the elastic pool, and the API for submitting work |
  | `JidoSwarm.Knowledge` | the shared graph's schema, over `Jido.Context` |
  | `JidoSwarm.LLM` | the model, local or Claude |
  | `JidoSwarm.Repos` | the repositories, and the git work |
  | `JidoSwarmWeb.ChatLive` | the operator's view of all of it |

  ## One graph per node, not per worker

  Every node runs a single `Jido.Context` graph that all its workers share, and
  the mesh replicates between nodes. Workers come and go by the second; the
  graph does not, and giving each worker its own replica of the same knowledge
  would multiply memory for nothing. Scaling the pool is therefore free of
  graph cost — what scales is attention, not storage.
  """

  @doc """
  The name of this node's context graph.

  Every worker reads and writes it; the mesh carries what it learns to the
  other nodes.
  """
  @spec graph() :: atom()
  def graph, do: :swarm_graph

  @doc """
  The Jido instance the swarm's agents register into.
  """
  @spec jido() :: atom()
  def jido, do: JidoSwarm.Jido

  @doc "The name of the context mesh this node belongs to."
  @spec mesh() :: atom()
  def mesh, do: :swarm_mesh

  @doc """
  Registers the configured repositories in the knowledge graph.

  Runs at startup, and is idempotent — repositories are upserted by key.
  """
  @spec register_repos() :: :ok
  def register_repos do
    Enum.each(JidoSwarm.Repos.all(), fn repo ->
      JidoSwarm.Knowledge.put_repo(graph(), repo)
    end)
  end

  @doc "Is the graph engine available? False means glider_ex is missing."
  @spec graph_available?() :: boolean()
  def graph_available?, do: Jido.Context.available?()
end
