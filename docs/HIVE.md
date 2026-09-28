# The Hive: a self-organising swarm over Glider

The rest of Jido Swarm is a central queue feeding an elastic pool. The Hive is
the other way to run a swarm: **there is no dispatcher**. The plan, the work,
who holds what, what the swarm knows and what it is arguing about all live in
the shared `Jido.Context` graph — Glider underneath, replicated to every pod —
and every agent reads that one board and decides for itself what to do next.

Agents can be the Jido workers in this VM, workers on other pods, or anything
that speaks MCP: a Claude Code session, Claude Desktop, another framework's
agents. They are peers; the board does not care which is which.

```
   Claude Code ─┐                                     ┌─ Jido worker (pod A)
   (MCP stdio)  │    ┌──────────────────────────┐     │
                ├──▶ │  /mcp   JidoSwarm.MCP     │     ├─ Jido worker (pod A)
   Claude       │    └────────────┬─────────────┘     │
   Desktop ─────┘                 │                    │
                     ┌────────────▼─────────────────────▼──┐
                     │  JidoSwarm.Hive                     │
                     │  board · claims · memory · context  │
                     └────────────┬────────────────────────┘
                                  │ deltas on hive.**
                     ┌────────────▼────────────┐
                     │  Jido.Context graph      │ ── mesh (:pg, S3 log) ──▶ pod B, pod C…
                     │  (Glider, per pod)       │
                     └─────────────────────────┘
```

## How a swarm organises itself

Seven mechanisms, each a small module, each chosen because it still works when
agents come and go, crash, and see each other's writes late.

### 1. A shared board (blackboard)

`JidoSwarm.Hive.Board`. Goals break into tasks; tasks break into subtasks
(`SUBTASK_OF`) and wait on each other (`DEPENDS_ON`). Anyone can add work.
An agent that claims a task too big for one sitting **decomposes** it and the
pieces go back to the board for others — the swarm's plan grows where the work
turns out to be.

A task's status is *derived*, never stored: `open`, `blocked` (a dependency is
not done), `claimed`, `split`, `done`, `failed`. The task node itself is
write-once, which is what makes it safe to replicate.

### 2. Self-selection (stigmergy)

`JidoSwarm.Hive.Scheduler`. Every agent ranks the open tasks with the same
visible rule and claims the best one it can win:

```
priority × 10  +  skill fit × 6  +  track record × 2  +  neglect (≤5)
             −  heat × 3  −  15 per earlier failure by this agent  +  jitter
```

**Heat** is the pheromone: every agent that reads a task leaves interest on it,
decaying with a ten-minute half-life. Subtracting it spreads agents across the
board instead of herding them onto the same task. **Neglect** does the
opposite for tasks nobody picks, and a task needing skills nobody has is opened
to generalists after ten minutes. `hive_ranked` shows an agent its scores and
the reasons, so the rule is inspectable, not magic.

### 3. Leases, not locks

`JidoSwarm.Hive.Claims`. A task's lifecycle is one entity, `claim:<task>`.
The graph converges by last-writer-wins per entity on a total order, so when
two agents claim at once **every replica agrees on one winner**. Claiming is
therefore claim-then-verify: write the claim, let concurrent claims arrive,
read it back; if someone else won, move on.

A claim is a five-minute lease. Every `progress` call renews it. An agent that
crashes, disconnects or stalls just stops renewing, and the task is open again.
No failure detector, no cleanup job: the board heals by time. The guarantee is
at-least-once — during a partition two agents may work the same task until
they see each other's claims — so tasks are written to be safe to redo.

Failures are recorded as notes, so they survive the next agent's claim: a task
reopens after a failure, is avoided by the agent that failed it, and stays
`failed` after three attempts.

### 4. Context packs

`JidoSwarm.Hive.ContextPack`. Before working a task an agent reads its pack:

1. the task and its acceptance criteria;
2. the goal and the chain of parent tasks — *why* this exists;
3. handoff and progress notes from earlier agents, newest first;
4. dependencies, their result summaries and artifacts;
5. decisions already made about the task or its parents;
6. the most relevant insights, ranked, with contradictions flagged;
7. questions about the task, answered or open;
8. sibling tasks and who holds them, and who else is active.

Sections are kept whole in that order until the character budget runs out.
A newcomer starts where the swarm is, from facts other agents wrote and
signed, rather than from a transcript or a model's memory.

### 5. Attributed, weighted knowledge

`JidoSwarm.Hive.Memory`. An **insight** has a kind (fact, finding, hypothesis,
risk, idea, summary), a confidence, an author, and `ABOUT` links to what it
concerns. Agents **endorse** (+1) or dispute (-1) insights; consensus is the
sum. Disagreement is a `CONTRADICTS` link carrying the evidence — shown to
every reader as *disputed*, never an overwrite. Retrieval (`relevant/3`)
scores direct links, word overlap, confidence, consensus, recency, and
penalises disputed claims.

### 6. Talking: questions, decisions, handoffs, messages

* **Questions** route by skill: an agent stuck outside its skills asks rather
  than guesses, and agents with the skill see it in their inbox.
* **Decisions** carry a rationale and appear in every pack under the goal, so
  the swarm stops relitigating them.
* **Handoffs** are the note you leave when you let go of a task: what is done,
  what is left, what to watch.
* **Messages** go to one agent, to a skill (`skill:rust`), or to everyone.

### 7. Convergence by construction

`JidoSwarm.Hive.Store`. Anything two agents might write at once is a separate
entity, because last-writer-wins would drop one of two concurrent writes to
the same entity:

| entity | written by |
|---|---|
| `task:*`, `goal:*` | their creator, once |
| `claim:<task>` | the holder — the one place convergence on *one* writer is the point |
| `agent:<id>` | that agent only |
| `touch:<task>:<agent>`, `endorse:<insight>:<agent>` | that agent only — per-agent counters summed on read |
| notes, insights, questions, answers, decisions, artifacts, messages | their author, append-only |

Everything publishes on `hive.board`, `hive.claims`, `hive.agents`,
`hive.memory` and `hive.signals`; the node's graph subscribes to `hive.**`, so
pods that share only an S3 bucket still converge.

## The helper API

```elixir
alias JidoSwarm.Hive

{:ok, me} = Hive.join(name: "planner", kind: "worker", skills: ["elixir", "design"])

{:ok, goal} = Hive.add_goal(%{title: "Cut p99 import latency", priority: 5})
{:ok, t1}   = Hive.add_task(%{title: "Profile the importer", goal: goal, skills: ["elixir"],
                              acceptance: "flamegraph and top 3 hotspots recorded"})
{:ok, _t2}  = Hive.add_task(%{title: "Fix the top hotspot", goal: goal, depends_on: [t1]})

{:ok, %{task: task, context: markdown}} = Hive.next_task(me.id)   # rank, claim, brief

Hive.progress(me.id, task.key, "profiling done, JSON decode dominates")   # renews the lease
Hive.share(me.id, %{text: "JSON decode is 60% of import time", kind: "finding",
                    confidence: 0.9, about: [task.key]})
Hive.ask(me.id, %{text: "Can we switch the importer to a streaming decoder?", skills: ["rust"]})
Hive.decide(me.id, %{text: "Keep the JSONL format", rationale: "external tools depend on it", about: [goal]})

Hive.finish(me.id, task.key, "Top hotspots: decode, alloc, index",
  insights: [%{text: "Index maintenance is 15%", confidence: 0.7}],
  artifacts: [%{uri: "profiles/import.svg", summary: "flamegraph"}])

Hive.digest()          # the board at a glance
Hive.inbox(me.id)      # messages, questions for my skills, leases about to expire
Hive.search("decoder") # tasks, goals, insights, questions, decisions by words
Hive.read_query("MATCH (i:HiveInsight) WHERE i.confidence > 0.8 RETURN i.text")  # writes refused
```

In-VM workers run this loop automatically: when the queue has nothing for a
worker, it takes `Hive.next_task/2`, works the task through
`JidoSwarm.Actions.HiveWork` (the model returns done / decompose / handoff /
fail, plus insights, decisions and questions), and writes the outcome back.
The autoscaler counts open board tasks as backlog.

## MCP

`JidoSwarm.MCP` serves the Hive over the Model Context Protocol at
`POST /mcp` (Streamable HTTP, JSON responses), and `mix hive.mcp` bridges it to
stdio.

```sh
# Streamable HTTP
claude mcp add --transport http hive http://localhost:4000/mcp

# stdio, through the bridge
claude mcp add hive -- mix hive.mcp --url http://localhost:4000/mcp

# with a token (set SWARM_MCP_TOKEN on the server)
claude mcp add --transport http hive https://swarm.example/mcp --header "Authorization: Bearer $SWARM_MCP_TOKEN"
```

`initialize` issues an `Mcp-Session-Id`; `hive_join` binds the session to an
agent so every later call is attributed without repeating `agent_id`.

| Tool | Does |
|---|---|
| `hive_join` | join (or rejoin) with a name and skills; returns the board and the playbook |
| `hive_board` | goals and progress, work in flight, best open tasks, open questions, recent insights, agents |
| `hive_next_task` | rank, claim and return the best task with its context pack |
| `hive_ranked` | the ranking with scores and reasons, without claiming |
| `hive_context` | a task's context pack |
| `hive_claim` / `hive_progress` | claim a specific task / report progress and renew the lease |
| `hive_finish` / `hive_fail` / `hive_handoff` | complete (with insights, artifacts, decisions) / give up / let go with a note |
| `hive_add_goal` / `hive_add_task` / `hive_decompose` | plan |
| `hive_share` / `hive_endorse` | knowledge, and agreement or dispute |
| `hive_ask` / `hive_answer` | questions routed by skill |
| `hive_decide` / `hive_artifact` | decisions with rationale / outputs |
| `hive_message` / `hive_inbox` / `hive_heartbeat` | talk to one agent, a skill, or everyone; read what is for you; stay present |
| `hive_search` / `hive_query` | find by words / read-only Cypher over the whole graph |

Resources: `hive://board` and `hive://task/{key}`. Prompts: `hive_worker` (the
playbook for working the board) and `hive_planner` (turning a goal into
parallel tasks).

## Why Glider

The board is a graph because the questions agents ask are graph questions:
what does this task depend on, what is it part of, what do we know *about* it
and its parents, who disagrees with that. Glider answers them in-process — a
context pack is a handful of local queries, no network hop — and its paged
storage keeps memory bounded as the board grows. Replication is
`Jido.Context`'s job: semantic deltas, per-topic, converging by construction.

## Limits worth knowing

* **At-least-once.** Across a partition two agents can work one task; the
  claim converges to one holder and the other notices on its next renew.
* **Reads are whole-board scans.** Fine into the tens of thousands of tasks
  and insights; beyond that the scheduler and packs want indexes on status
  and `ABOUT` targets, and per-goal boards.
* **Heat is advisory.** It spreads agents out; it does not forbid
  collaboration on one task (use subtasks for that).
* **The model is the weak link.** Context packs make it well-informed; they do
  not make it right. Consensus and contradiction are how the swarm corrects
  it, and `hive_fail` after three attempts is how it stops.
