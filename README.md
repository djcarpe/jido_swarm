# Jido Swarm

An elastic swarm of [Jido](https://github.com/agentjido/jido) agents that share a
knowledge graph and work on code, with a Phoenix LiveView chat in front of it.

The swarm surveys three repositories — `jido`, `glider` and `glider_ex` —
records what it learns in a graph every member can read, proposes features that
follow from those findings, and implements the ones you ask it to: on a branch,
with the test suite run, and a pull request opened.

```
                    ┌──────────────────────┐
  you ──chat──────▶ │  ChatLive            │
                    └──────────┬───────────┘
                               │ jobs
                    ┌──────────▼───────────┐
                    │  Queue               │ ◀── Autoscaler adds/retires workers
                    └──────────┬───────────┘
              ┌────────────────┼────────────────┐
         ┌────▼────┐      ┌────▼────┐      ┌────▼────┐
         │ worker  │      │ worker  │      │ worker  │   each drives a Jido agent
         └────┬────┘      └────┬────┘      └────┬────┘
              └────────────────┼────────────────┘
                    ┌──────────▼───────────┐
                    │  Jido.Context graph  │ ── mesh ──▶ other pods
                    └──────────────────────┘
```

## Running it

Needs Elixir 1.18+ and an Anthropic API key:

```sh
export ANTHROPIC_API_KEY=sk-ant-...
mix deps.get
mix phx.server
```

Then open http://localhost:4000 and press **Run a cycle**.

To run against a local model instead, point it at [Ollama](https://ollama.com):

```sh
ollama pull qwen3:4b-instruct
LLM_PROVIDER=ollama mix phx.server
```

## The Hive: a self-organising swarm, and MCP

Besides the queue, the swarm can run with **no dispatcher at all**: goals,
tasks, leases, knowledge and conversation live in the shared graph, and every
agent — the Jido workers here, workers on other pods, or Claude Code over MCP —
reads the board and picks its own work. Idle workers do this automatically.

```sh
claude mcp add --transport http hive http://localhost:4000/mcp   # join from Claude Code
```

Leases that heal by time, a scheduler every agent runs identically, context
packs that brief a newcomer from what others wrote, weighted and disputable
insights, skill-routed questions — all converging over the mesh by
construction. See [`docs/HIVE.md`](docs/HIVE.md).

A steward keeps the board fed: a standing goal with one live task per
repository, re-opened round after round (`SWARM_STANDING_GOAL`,
`SWARM_CYCLE_EVERY_MS`), so the swarm learns without being clicked.

The Hive tab shows the shared memory *as* shared: which pod you are on, how
much of its graph other pods wrote, the graph itself drawn live and coloured
by origin, deltas as they arrive, a "ping the mesh" that every other pod
answers through the graph, and a race between two pods' writes that the
last-writer-wins rule settles in front of you.

## What the parts are

| Module | Role |
|---|---|
| `JidoSwarm.Swarm` | the elastic pool, and the API for submitting work |
| `JidoSwarm.Swarm.Queue` | pending work, dispatch, job history |
| `JidoSwarm.Swarm.Autoscaler` | adds workers on backlog, retires them when idle |
| `JidoSwarm.Swarm.Worker` | a pull loop around one `Jido.AgentServer` |
| `JidoSwarm.Knowledge` | the shared graph's schema, over `Jido.Context` |
| `JidoSwarm.LLM` | the model — local Ollama, or Claude |
| `JidoSwarm.Repos` | the repositories, cloning, branching, testing, PRs |
| `JidoSwarmWeb.ChatLive` | the operator's view of all of it |
| `JidoSwarm.Hive` | the self-organising board: goals, tasks, leases, shared memory, context packs |
| `JidoSwarm.MCP` | the Hive as MCP tools, resources and prompts at `/mcp`; `mix hive.mcp` for stdio |

## The model

Claude by default (`claude-opus-5`, adaptive thinking on), with the local model
as the opt-out. The prompts are provider-neutral and each provider translates
at the edge, so switching changes nothing but the answers' quality.

| Variable | |
|---|---|
| `ANTHROPIC_API_KEY` | required |
| `ANTHROPIC_WORKSPACE_ID` | only for an **organization-scoped** key |
| `LLM_PROVIDER=ollama` | use the local model instead |

> **An org-scoped key needs a workspace.** Anthropic rejects every request from
> one with `invalid_request_error` until it is told which workspace to bill,
> and the swarm surfaces that as every job failing. Either set
> `ANTHROPIC_WORKSPACE_ID`, or use a workspace-scoped key, which carries its
> workspace implicitly.

### The local model

```elixir
ollama: [base_url: "http://127.0.0.1:11434", model: "qwen3:4b-instruct", num_ctx: 16_384]
```

> **`num_ctx` is not optional.** Ollama defaults to a 4096-token window
> regardless of what the model advertises. `qwen3:4b-instruct` claims 262144 and
> still rejects a 5262-token prompt until the window is set explicitly — which is
> why `JidoSwarm.LLM.Ollama` speaks the native `/api/chat` rather than the
> OpenAI-compatible endpoint, which gives no way to set it.

## Elasticity

`JidoSwarm.Swarm.Autoscaler` reads the queue every couple of seconds:

- **out** when work is pending and no worker is free, `scale_step` at a time up
  to `max_workers`;
- **in** when workers have sat idle for `idle_ttl` with nothing pending, down to
  `min_workers`.

The idle timer is what keeps it from oscillating — a queue that empties for one
tick would otherwise retire workers that are about to be needed, and a cold
worker costs an agent start plus a fresh model connection.

## The knowledge graph

One `Jido.Context` graph per node, shared by every worker on it, replicated
between nodes by the mesh. Workers come and go by the second; the graph does
not, and a replica per worker would multiply memory for nothing.

```
(:Repo)   ←[:ABOUT]────  (:Finding)
   ↑                         ↑
[:FOR]                 [:SUPPORTED_BY]
   │                         │
(:Proposal) ←[:IMPLEMENTS]─ (:Attempt)
```

Nothing gets proposed that is not grounded in a finding, and every finding came
from a worker actually reading the code. Ask the chat what it knows and the
answer is assembled from this graph, not from the model's memory.

With `SWARM_S3_BUCKET` set, snapshots and a topic log go to object storage, so
pods that share nothing but a bucket still converge, and a restarted pod boots
knowing what the swarm already learned.

### Taking the graph with you

`GET /export/graph` downloads this replica's whole graph as JSON Lines —
Glider's export, mesh stamps included — and `/export/knowledge`,
`/export/context` and `/export/hive` cut it down to what was published on
those topics, keeping only edges whose both ends are kept. The Hive and
Glider tabs link to all four. The file imports back with
`Jido.Context.import/2` or `glider <db> import`.

## Working on repositories

The swarm clones each repository into its own workspace and works there. **It
never touches your checkout** — agents acting on a tree you are also using is
how uncommitted work disappears. A local checkout is used as the clone source
when one exists (fast, offline), but `origin` is repointed at GitHub so a branch
can be pushed.

An implementation attempt runs branch → draft edits → write → **test** → commit
→ push → PR, recording each stage in the graph as it happens. Two things it will
not do:

- **No pull request over a failing suite.** A red suite ends the attempt with the
  output recorded. Opening PRs regardless would make the swarm a machine for
  generating review burden.
- **No writing outside the repository.** Model-supplied paths go through
  `JidoSwarm.Repos.safe_path/2`.

Without `GITHUB_TOKEN` the work still happens — it stops after the commit, and
the attempt says so.

## Instrumentation

Besides the Glider engine events below, the vendored `Jido.Context` emits
`[:jido, :context, :delta, :applied]` for every delta the graph applies,
tallying operations applied, superseded or tombstoned, and
`[:jido, :context, :mesh, :publish | :deliver | :duplicate]` from the mesh
router. `JidoSwarm.Hive.Feed` consumes them for the Hive tab.

Every call into Glider is wrapped in `:telemetry.span/3`, so the graph is
measured at the one seam every operation passes through:

```
[:jido, :context, :glider, <op>, :start | :stop | :exception]
```

for `open`, `query`, `run`, `import`, `export`, `checkpoint` and `stats`.
`JidoSwarm.GliderMetrics` collects them and the **Glider** tab shows:

| | |
|---|---|
| Usage | operations, time spent in Glider, rows read, entities written |
| Latency | p50 / p95 / p99 / max, per operation |
| Errors | per operation and overall, as a rate |
| Throughput | operations per second over the last five minutes |
| Shape | calls grouped by Cypher keyword |

Three decisions worth knowing:

**Percentiles, not averages.** Graph work is bimodal — an indexed lookup is
microseconds, a `CALL pagerank` is seconds — so a mean sits in the empty space
between the two and describes nothing that ever happens.

**Failures are measured, not just logged.** A failed query emits a `:stop` with
`result: :error`. An operation that emitted nothing on failure would make an
outage read as idleness.

**The statement text is never recorded**, only its leading keyword. That
separates a `MATCH` from a `CALL` without putting entity keys and property
values into telemetry. There is a test asserting a secret property value never
reaches metadata.

Collection writes straight to ETS from the calling process rather than through
a GenServer: a collector on the hot path of every graph operation would
serialise all graph work behind one mailbox and become the bottleneck it exists
to measure.

## Deploying

```sh
kubectl apply -f k8s/
```

`k8s/examples/secret.example.yaml` lists what the Secret needs. It is in a
subdirectory deliberately — `kubectl apply -f k8s/` is not recursive, so the
example cannot overwrite a working Secret with its empty placeholders.

Required: `SECRET_KEY_BASE`, `RELEASE_COOKIE`, and `ANTHROPIC_API_KEY`.
`GITHUB_TOKEN` is optional (without it the swarm implements and tests but does
not push). `ANTHROPIC_WORKSPACE_ID` is needed **only for an organization-scoped
key** — a workspace-scoped key carries its workspace implicitly.

### Durability

A StatefulSet, not a Deployment, for two reasons that both come from the mesh:

- **Per-replica PVCs**, so a graph survives rescheduling. The mesh can rebuild
  a lost replica from its peers, but only while a peer is up — a simultaneous
  restart of every pod would otherwise lose everything learned.
- **Stable identities.** A pod's name is its origin in the mesh, and the mesh
  orders writes by `{seq, origin}`. Deployment pods get a fresh random name on
  every restart, so a replica's history became a stranger's each time it came
  back.

### GitOps

Push to `main` and the cluster picks it up:

```
GitHub Actions ──build──▶ GHCR ◀──poll── CronJob ──patch──▶ StatefulSet
```

Pull-based because this homelab is behind NAT — a push pipeline would need an
inbound path from GitHub that does not exist. The syncer resolves what `:latest`
points at and patches the StatefulSet to that **digest**, which is what makes
the rollout deterministic and a real trigger; patching back to the same tag
would change nothing and roll out nothing.

Its RBAC is one verb on one workload in one namespace. A credential that can
deploy code is worth scoping.

Deployed pods reach the model through `ollama-external`, a Service with
hand-managed Endpoints pointing at the workstation. Ollama binds `127.0.0.1` by
default, so it has to be told to listen on the LAN:

```sh
sudo mkdir -p /etc/systemd/system/ollama.service.d
printf '[Service]\nEnvironment="OLLAMA_HOST=0.0.0.0:11434"\n' \
  | sudo tee /etc/systemd/system/ollama.service.d/10-lan-bind.conf
sudo systemctl daemon-reload && sudo systemctl restart ollama
```

> The runtime image carries Elixir **and** Rust, because the swarm runs
> `mix test` and `cargo test` inside the repositories it clones. That makes it
> large; it is a build agent, not a web server that happens to have a UI. Build
> with `--build-arg WITH_RUST=false` to drop the Rust half if you do not need
> glider's suite to run.

## The vendored trees

`vendor/` holds `jido`, `glider` and `glider_ex`: the first carries unreleased
`Jido.Context` work, and the latter two are not on Hex. Refresh them from your
working checkouts with:

```sh
mix vendor.refresh
```
