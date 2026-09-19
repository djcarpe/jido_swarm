defmodule JidoSwarm.Swarm.WorkerAgent do
  @moduledoc """
  The Jido agent a swarm worker drives.

  Jobs arrive as signals — `swarm.survey`, `swarm.propose`, `swarm.implement`,
  `swarm.chat` — and route to the matching action. Keeping the work in actions
  rather than in the worker process is what makes it reusable: the same actions
  run from a Livebook, a test, or a `mix` task with no swarm around them.

  ## Why the context graph is not mounted here

  `Jido.Context.Plugin` starts a graph *per agent*, under a registered name that
  must be unique. An elastic pool creates and destroys agents continuously, so
  per-agent graphs would mean a per-agent name to invent and a full replica of
  the knowledge graph per worker — many copies of the same data in one VM.

  Instead the node runs a single graph (`JidoSwarm.graph/0`) that every worker
  on it reads and writes, and the mesh replicates *between* nodes. One replica
  per pod, not one per worker, which is the granularity that actually matters.
  """

  use Jido.Agent,
    name: "swarm_worker",
    description: "A swarm member that surveys repositories, proposes features, and implements them",
    schema: [
      jobs_run: [type: :integer, default: 0],
      last_job: [type: :string, default: ""]
    ]

  @impl true
  def signal_routes(_ctx) do
    [
      {"swarm.survey", JidoSwarm.Actions.Survey},
      {"swarm.propose", JidoSwarm.Actions.Propose},
      {"swarm.implement", JidoSwarm.Actions.Implement},
      {"swarm.chat", JidoSwarm.Actions.Chat}
    ]
  end
end
