# Jido Usage Rules

## Intent
Build reliable multi-agent systems by keeping decision logic pure and runtime effects explicit.
<!-- package.jido.pure_cmd package.jido.runtime_separation -->

## Core Contracts
- Treat `cmd/2` as the core agent contract: `{updated_agent, directives}`.
- Keep agent logic pure; directives describe external effects only.
- Use **Zoi-first** schemas for new agents, directives, plugins, and signals.
- Preserve tagged tuple and structured error contracts at public boundaries.
- Use AgentServer/runtime modules for process concerns, not agent module internals.

## Library Author Patterns
- Author actions for domain behavior; let agents orchestrate state + directive emission.
- Use `Directive.SpawnAgent` / `Directive.StopChild` for hierarchy, not ad-hoc child tracking.
- Use signals for cross-agent communication instead of direct process coupling.
- Keep plugin/sensor concerns isolated and composable.

## QA Patterns
- Start with pure `cmd/2` tests, then add AgentServer integration tests.
- Start an isolated Jido instance per runtime test and prefer await/polling assertions over fixed sleeps.
- Run `mix q` (`mix quality`) and coverage checks before release.

## Shared Context & Knowledge
- Mount `Jido.Context.Plugin` to give an agent a graph; start one `Jido.Context.Mesh` per application, not per agent.
- Give every graph a unique `:origin` — two graphs sharing one tie in the last-writer-wins ordering and diverge.
- Choose entity keys another agent could arrive at independently (`"paper:10.1234/xyz"`), not generated ids.
- Keep `:location` (where the graph lives) and `:store` (where snapshots go) as separate decisions.
- Pair `:pg` with a `{:log, store: ...}` transport when agents must converge on knowledge produced before they started.
- Never build Cypher by string interpolation; go through `Jido.Context` so values are escaped and identifiers validated.

## Avoid
- Embedding runtime side effects directly in core state transition code.
- Using directives as a hidden state-mutation mechanism.
- Tight coupling between unrelated agent modules.

## References
- `README.md`
- `guides/`
- `test/AGENTS.md`
- `AGENTS.md`
- https://hexdocs.pm/jido
- https://hexdocs.pm/usage_rules/readme.html#usage-rules
