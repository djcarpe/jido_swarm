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

Needs Elixir 1.18+, and [Ollama](https://ollama.com) with a tool-capable model:

```sh
ollama pull qwen3:4b-instruct
mix deps.get
mix phx.server
```

Then open http://localhost:4000 and press **Run a cycle**.

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

## The model

Ollama by default, so it runs with no API key:

```elixir
config :jido_swarm, JidoSwarm.LLM,
  provider: JidoSwarm.LLM.Ollama,
  ollama: [base_url: "http://127.0.0.1:11434", model: "qwen3:4b-instruct", num_ctx: 16_384]
```

Switching to Claude is two environment variables — `ANTHROPIC_API_KEY` and
`LLM_PROVIDER=anthropic`. Nothing else changes: the prompts are
provider-neutral, and the providers translate at the edge.

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

## Deploying

```sh
docker build -t jido-swarm:latest .
kubectl apply -f k8s/
```

See `k8s/` for the manifests and `k8s/21-secret.example.yaml` for what they
need. The only genuinely required secret is `SECRET_KEY_BASE`; everything else
degrades rather than failing.

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
