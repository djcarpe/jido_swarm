# Context and knowledge graphs

Agents accumulate two things worth keeping.

**Knowledge** is what they come to believe about the world — entities, and the
relations between them. It is meant to outlive the task that discovered it: the
paper the scout found last week should still be there when the analyst needs it.

**Context** is what is true of a particular piece of work — a session, a task, a
conversation. It is scoped and short-lived, but while it lasts, every agent
touching that task needs the same view of it.

Both are graphs. And agents working together need them to be the *same* graph.
`Jido.Context` is that graph: an embedded property database per agent, with
what each agent learns replicated to the others by topic.

```
    ┌──────────┐      ┌──────────┐      ┌──────────┐
    │ agent A  │      │ agent B  │      │ agent C  │
    │  graph   │      │  graph   │      │  graph   │
    └────┬─────┘      └────┬─────┘      └────┬─────┘
         │ deltas          │                 │
         └────────────┬────┴─────────────────┘
                      │
                ┌─────┴──────┐
                │    mesh    │   routes by topic
                └─────┬──────┘
           ┌──────────┴──────────┐
           │                     │
        :pg (cluster)      topic log (S3)
```

Every agent holds a **full replica**. A read is a function call into an
in-process database — no network, no coordinator, no query planner on the other
side of a socket. Convergence happens asynchronously in the background.

## Installing the engine

The graph is [Glider](https://github.com/agentjido/glider), an embedded
property-graph database in the shape SQLite took for relational data: one file,
no server, linked into the BEAM as a NIF. It is an **optional** dependency,
because building it needs a Rust toolchain and that is not a cost every Jido
application should pay:

```elixir
def deps do
  [
    {:jido, "~> 2.3"},
    {:glider_ex, "~> 0.1"}
  ]
end
```

Without it, `Jido.Context.available?/0` returns `false` and starting a graph
fails with an explanatory error. Jido itself compiles and runs either way.

## A first graph

```elixir
{:ok, _} = Jido.Context.start_mesh(name: :research, transports: [:pg])
{:ok, _} = Jido.Context.start_graph(name: :scout, mesh: :research)

Jido.Context.assert(:scout, "paper:attention", ["Paper"],
  %{title: "Attention Is All You Need", year: 2017},
  topic: "knowledge.papers"
)

Jido.Context.relate(:scout, "paper:attention", "CITES", "paper:seq2seq",
  topic: "knowledge.papers"
)

{:ok, result} =
  Jido.Context.query(:scout, "MATCH (p:Paper) WHERE p.year > 2015 RETURN p.title")
```

The first argument to `assert/5` is the entity's **key**: its identity across
the whole mesh. Choose something stable and meaningful — `"paper:10.1234/xyz"`,
`"user:42"` — not a generated id, because the point is that a second agent
arrives at the same key independently and the two writes land on one node.

## Giving an agent a graph

`Jido.Context.Plugin` starts a graph under the agent and wires it to a mesh:

```elixir
defmodule MyApp.Scout do
  use Jido.Agent,
    name: "scout",
    plugins: [
      {Jido.Context.Plugin,
       %{graph: :scout_graph, mesh: :research, topics: ["knowledge.**"]}}
    ]
end
```

The mesh is started once for the application, not per agent:

```elixir
children = [
  {Jido.Context.Mesh, name: :research, transports: [:pg]},
  {MyApp.Scout, id: "scout"}
]
```

The plugin contributes five actions — `context.assert`, `context.relate`,
`context.remember`, `context.recall` and `context.query` — so an agent can read
and write the mesh by signal without any custom code:

```elixir
Jido.AgentServer.call(scout, Jido.Signal.new!("context.assert", %{
  key: "paper:attention",
  labels: ["Paper"],
  props: %{"year" => 2017},
  topic: "knowledge.papers"
}))
```

Settings that differ per environment — a bucket name, whether graphs live on
disk — belong in application config rather than the compile-time plugin config,
and fill in whatever it leaves out:

```elixir
config :jido, Jido.Context,
  location: {:disk, path: "/var/lib/myapp/graphs"},
  store: {:s3, bucket: "agent-graphs", prefix: "prod"}
```

## Memory, disk, and S3

Two settings, doing two different jobs. Keeping them apart is the whole of the
persistence story.

**`:location` — where the graph itself lives.**

| | |
|---|---|
| `:memory` *(default)* | nothing touches disk; the graph dies with the process |
| `{:disk, path: "g.gldb"}` | Glider opens a file that is its write-ahead log and its persistent form at once |

A disk-backed graph survives a restart on its own. Reads still never touch disk
— Glider holds the graph in memory and the file is the log.

**`:store` — where snapshots go.**

| | |
|---|---|
| `nil` *(default)* | no snapshots |
| `:memory` | into ETS; useful in tests |
| `{:disk, path: "dir"}` | JSON Lines files |
| `{:s3, bucket: ..., prefix: ...}` | objects, readable from anywhere |

A snapshot is a JSON Lines dump. It is engine-independent, which is what makes
it the thing that *moves*: a graph with a store restores from its snapshot on
boot, so an agent starting anywhere begins with what the mesh already knew.

They combine as you would expect. An in-memory graph with an S3 store is fast
to read, durable off-box, and costs no local disk:

```elixir
Jido.Context.start_graph(
  name: :scout,
  location: :memory,
  store: {:s3, bucket: "agent-graphs", prefix: "research"},
  snapshot_every: 100,
  mesh: :research
)
```

## Streaming across agents

A mesh carries deltas over any number of transports at once.

```elixir
Jido.Context.start_mesh(
  name: :research,
  transports: [
    :pg,
    {:log, store: {:s3, bucket: "agent-graphs", prefix: "research"}, interval: 1_000}
  ]
)
```

| Transport | Reach | Latency |
|---|---|---|
| `:pg` | agents sharing a BEAM cluster | a message send |
| `{:log, store: ...}` | anything that can read the store | the poll interval |

Running both is the usual production shape: co-located agents converge
instantly, and agents that share nothing but a bucket — another region, a batch
job, an agent that starts tomorrow — converge within the poll interval.

### What the log looks like in the bucket

```
members/knowledge.papers/scout                          a participant marker
topics/knowledge.papers/scout/00000000000000000007.json one delta, written once
```

Each delta is an immutable object. A retry is idempotent because the key is
derived from the delta's own stamp, and the mesh de-duplicates by delta id.

The log is partitioned by origin, and it is worth saying why: the obvious
design — one flat, time-ordered prefix per topic, tailed with S3's
`start-after` — has a race that loses data *silently*. Keys would have to sort
in write order, and they do not: agent A can write sequence 5 after agent B has
written 9, and a poller that already passed 9 will never list 5 again. The
delta sits in the bucket and no one ever reads it. Partitioning by origin
removes the assumption rather than narrowing it — each origin's own sequence
numbers are monotonic, so a per-origin cursor is exact and no two clocks ever
have to agree.

### Topics

Writes are tagged with a topic; subscribers register patterns.

```
"knowledge.papers"     exactly that topic
"knowledge.*"          knowledge.papers, not knowledge.papers.nlp
"knowledge.**"         both
"**"                   everything
```

Topics are how an agent avoids drowning in what it does not need. A planner
might take `["knowledge.**"]` while a narrow tool agent takes only
`["context.task_7"]`.

## Convergence

Deltas are stamped `{seq, origin}` — a Lamport clock and a stable per-graph
identity — and applied **last-writer-wins per entity**. Sequence first, origin
as the tiebreak. The order is total and every agent computes it identically, so
applying the same deltas in any order lands every graph in the same state.

Deletes leave a tombstone carrying the stamp of the deletion, so an assert that
was already in flight cannot resurrect a retracted fact. A genuinely newer
assert still can, which is the correct behaviour: the fact was re-learned.

Edges may arrive before the nodes they connect — routine when two agents
publish on different topics — so a missing endpoint is created as an unlabelled
placeholder and filled in when the real assert lands.

### Why deltas and not Glider's byte replication

Glider replicates by shipping byte ranges of its log file, which is an
excellent backup story and the wrong primitive here. It is single-writer — two
processes appending to one file corrupt it — and a restored file is a
point-in-time copy, not a follower that stays current. A mesh needs the
opposite: every agent writes to its own graph, and every agent converges on
what the others learned. So Jido replicates *semantic* operations, which are
idempotent and commutative under the ordering above.

## Context scopes

`remember/5` and `recall/3` are sugar for the scoped half of the graph:

```elixir
Jido.Context.remember(:planner, "task:42", "budget_remaining", 3)
Jido.Context.remember(:planner, "task:42", "owner", "scout")

Jido.Context.recall(:planner, "task:42")
#=> {:ok, %{"budget_remaining" => 3, "owner" => "scout"}}
```

Underneath they are ordinary nodes and edges — a `:CtxEntry` hanging off a
`:CtxScope` — so everything an agent knows about a task is one hop away, and
context and knowledge can be traversed in a single query.

## Querying

Glider speaks a Cypher subset: `MATCH`, `WHERE`, `RETURN`, `CREATE`, `SET`,
`DELETE`, aggregates, variable-length paths, and `CALL` for graph algorithms
(`pagerank`, `components`, `shortestpath`, `communities`, and more).

```elixir
Jido.Context.query(:scout, """
MATCH (a:Paper)-[:CITES*1..3]->(b:Paper)
WHERE a.year > 2015
RETURN b.title, count(a) AS citations
ORDER BY citations DESC LIMIT 10
""")
```

Two differences from full Cypher worth knowing: `RETURN` requires a `MATCH`
(there is no bare `RETURN 1`), and `count()` over zero matches returns zero
rows rather than one row holding `0` — use `Jido.Context.stats/2` for a count
that is always present.

### Reserved properties

Every managed entity carries its replication stamp, and user properties may not
begin with an underscore:

| Property | Meaning |
|---|---|
| `_key` | the entity's mesh-wide identity |
| `_seq`, `_origin` | the stamp that decides last-writer-wins |
| `_topic` | the topic the writing delta was published on |
| `_ts` | wall-clock time of the write, in ms |

Managed nodes also carry the `:Ctx` label alongside whatever labels you gave
them, and `:Ctx(_key)` is indexed. Tombstones carry `:CtxTomb` and nothing
else, so a query written against your own labels never encounters one.

### Injection

Glider has no bound parameters — a query is a string, and every value in it is
a literal — so `Jido.Context.Cypher` is the only place that turns Elixir terms
into query text, and it draws a hard line: **values are escaped, identifiers
are validated**. Labels, relationship types and property keys appear outside
quotes, where no escape would make an arbitrary binary safe, so they must match
`[A-Za-z_][A-Za-z0-9_]*` and are rejected otherwise — including when they
arrive inside a delta from a peer. Entity keys and property values are values,
not identifiers, and may contain anything.

## Seeing it work

```sh
mix jido.context.mesh                                    # three agents over :pg
mix jido.context.mesh --transport log --store disk       # three agents sharing only a store
mix jido.context.mesh --location disk --store disk       # run twice; the second starts knowing
```

The `--transport log` run is the interesting one: nothing passes between the
three agents directly. Each writes immutable objects and polls for what the
others wrote — the same code path as three agents on three machines sharing an
S3 bucket.

## Operational notes

- **One origin per graph.** Two graphs sharing an origin tie in the ordering and
  diverge. The origin defaults to the graph's name.
- **One writer per graph file.** Glider takes a file lock; a second open of the
  same path fails until the first closes. The graph process traps exits so the
  handle and lock are released when its agent stops.
- **The graph must fit in RAM.** Glider is memory-resident by design — that is
  what makes whole-graph algorithms fast. For knowledge- and context-graph
  sizes this is the right trade; for a billion edges it is not.
- **`:pg` alone is not durable.** A delta published while a peer is down is
  never seen by that peer. Add the log transport when agents must converge on
  knowledge produced before they started.
- **Snapshots are a bootstrap optimisation, not the source of truth.** They are
  overwritten in place; a graph that reads a stale one still converges by
  replaying the topic log after it.

## Reference

- `Jido.Context` — the facade, and the place to start
- `Jido.Context.Graph` — the process that owns a graph
- `Jido.Context.Mesh` — topic routing and transports
- `Jido.Context.Delta` — the replication unit and its ordering
- `Jido.Context.Store` — snapshot and log storage
- `Jido.Context.S3` — the S3 client, and `Jido.Context.S3.SigV4` for signing
- `Jido.Context.Plugin` — giving an agent a graph
