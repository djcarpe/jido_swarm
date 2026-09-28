defmodule JidoSwarm.MCP.Tools do
  @moduledoc """
  The Hive as MCP tools: everything an external agent needs to join the swarm,
  pick work, share what it learns and coordinate — the same loop the in-VM
  workers run, over JSON-RPC.

  Every tool acts as an agent. The agent is the one named by `agent_id`, or
  else the one this MCP session joined as with `hive_join`, so a client joins
  once and every later call is attributed.
  """

  alias JidoSwarm.Hive
  alias JidoSwarm.Hive.Memory

  @str %{"type" => "string"}
  @strs %{"type" => "array", "items" => %{"type" => "string"}}
  @int %{"type" => "integer"}
  @num %{"type" => "number"}

  defp obj(props, required \\ []) do
    %{
      "type" => "object",
      "properties" => props,
      "required" => required,
      "additionalProperties" => false
    }
  end

  defp agent_param,
    do: %{
      "agent_id" =>
        Map.put(@str, "description", "Acting agent; defaults to the one this session joined as")
    }

  defp insight_schema do
    obj(
      %{
        "text" => @str,
        "kind" => Map.put(@str, "enum", ~w(fact finding hypothesis risk idea summary)),
        "confidence" => Map.put(@num, "description", "0..1"),
        "about" => @strs,
        "tags" => @strs
      },
      ["text"]
    )
  end

  @doc "Tool definitions as MCP expects them, plus the handler for each."
  @spec all() :: [map()]
  def all do
    [
      tool(
        "hive_join",
        "Join the swarm (or rejoin with agent_id). Call this first. Returns your agent id, the board and how to work.",
        obj(
          %{
            "name" => @str,
            "skills" => @strs,
            "kind" => @str,
            "model" => @str,
            "agent_id" => @str
          },
          ["name"]
        ),
        &join/2,
        write: true
      ),
      tool(
        "hive_board",
        "The board at a glance: goals and progress, tasks in flight and who holds them, the best open tasks, open questions, recent insights, active agents.",
        obj(%{"limit" => @int}),
        fn a, _ -> {:ok, Hive.digest(limit: a["limit"] || 10)} end
      ),
      tool(
        "hive_next_task",
        "Pick the best open task for you, claim it, and get its context pack. Returns nothing to do if the board is empty for your skills.",
        obj(Map.merge(agent_param(), %{"skills" => @strs})),
        &next_task/2,
        write: true
      ),
      tool(
        "hive_ranked",
        "Open tasks ranked for you, with the score and the reasons, without claiming anything.",
        obj(Map.merge(agent_param(), %{"limit" => @int})),
        &ranked/2
      ),
      tool(
        "hive_context",
        "The context pack for a task: goal, parents, handoff notes, inputs, decisions, relevant knowledge, open questions, and who is working nearby.",
        obj(
          %{"task" => @str, "budget" => Map.put(@int, "description", "characters, ~4 per token")},
          ["task"]
        ),
        &context/2
      ),
      tool(
        "hive_claim",
        "Claim a specific task (lease 5 minutes; renew with hive_progress).",
        obj(Map.merge(agent_param(), %{"task" => @str}), ["task"]),
        &claim/2,
        write: true
      ),
      tool(
        "hive_progress",
        "Report progress on a task you hold. Renews your lease — keep calling it while you work.",
        obj(Map.merge(agent_param(), %{"task" => @str, "note" => @str}), ["task", "note"]),
        &progress/2,
        write: true
      ),
      tool(
        "hive_finish",
        "Complete a task you hold, recording a summary and what came out of it.",
        obj(
          Map.merge(agent_param(), %{
            "task" => @str,
            "summary" => @str,
            "insights" => %{"type" => "array", "items" => insight_schema()},
            "artifacts" => %{
              "type" => "array",
              "items" => obj(%{"uri" => @str, "kind" => @str, "summary" => @str}, ["uri"])
            },
            "decisions" => %{
              "type" => "array",
              "items" => obj(%{"text" => @str, "rationale" => @str}, ["text"])
            }
          }),
          ["task", "summary"]
        ),
        &finish/2,
        write: true
      ),
      tool(
        "hive_fail",
        "Give up on a task you hold, saying why. It reopens for others (up to 3 attempts).",
        obj(Map.merge(agent_param(), %{"task" => @str, "reason" => @str}), ["task", "reason"]),
        &fail/2,
        write: true
      ),
      tool(
        "hive_handoff",
        "Release a task you hold with a note for whoever picks it up next: what is done, what is left, what to watch out for.",
        obj(Map.merge(agent_param(), %{"task" => @str, "note" => @str}), ["task", "note"]),
        &handoff/2,
        write: true
      ),
      tool(
        "hive_add_goal",
        "Add a top-level goal for the swarm to organise around.",
        obj(
          Map.merge(agent_param(), %{
            "title" => @str,
            "description" => @str,
            "priority" => Map.put(@int, "description", "1..5")
          }),
          ["title"]
        ),
        &add_goal/2,
        write: true
      ),
      tool(
        "hive_add_task",
        "Add a task under a goal or a parent task. depends_on lists task keys that must be done first; skills route it to the right agents.",
        obj(
          Map.merge(agent_param(), %{
            "title" => @str,
            "detail" => @str,
            "acceptance" => @str,
            "goal" => @str,
            "parent" => @str,
            "depends_on" => @strs,
            "skills" => @strs,
            "priority" => @int
          }),
          ["title"]
        ),
        &add_task/2,
        write: true
      ),
      tool(
        "hive_decompose",
        "Split a task that is too big into subtasks. A subtask can depend on an earlier one by index (depends_on: [0]). The parent completes when all subtasks do.",
        obj(
          Map.merge(agent_param(), %{
            "task" => @str,
            "subtasks" => %{
              "type" => "array",
              "items" =>
                obj(
                  %{
                    "title" => @str,
                    "detail" => @str,
                    "acceptance" => @str,
                    "skills" => @strs,
                    "priority" => @int,
                    "depends_on" => %{"type" => "array", "items" => %{}}
                  },
                  ["title"]
                )
            }
          }),
          ["task", "subtasks"]
        ),
        &decompose/2,
        write: true
      ),
      tool(
        "hive_share",
        "Share an insight with the swarm: a fact, finding, hypothesis, risk, idea or summary, with a confidence. Link it to what it is about, what it supports or contradicts.",
        obj(
          Map.merge(
            agent_param(),
            Map.merge(insight_schema()["properties"], %{
              "supports" => @strs,
              "contradicts" => @strs
            })
          ),
          ["text"]
        ),
        &share/2,
        write: true
      ),
      tool(
        "hive_endorse",
        "Endorse (+1) or dispute (-1) an insight. One vote per agent.",
        obj(Map.merge(agent_param(), %{"insight" => @str, "weight" => @int}), ["insight"]),
        &endorse/2,
        write: true
      ),
      tool(
        "hive_ask",
        "Ask the swarm a question, routed to agents with the given skills and tied to a task if relevant.",
        obj(Map.merge(agent_param(), %{"text" => @str, "skills" => @strs, "about" => @strs}), [
          "text"
        ]),
        &ask/2,
        write: true
      ),
      tool(
        "hive_answer",
        "Answer a question.",
        obj(Map.merge(agent_param(), %{"question" => @str, "text" => @str}), ["question", "text"]),
        &answer/2,
        write: true
      ),
      tool(
        "hive_decide",
        "Record a decision and its rationale, so the swarm stops relitigating it.",
        obj(Map.merge(agent_param(), %{"text" => @str, "rationale" => @str, "about" => @strs}), [
          "text"
        ]),
        &decide/2,
        write: true
      ),
      tool(
        "hive_artifact",
        "Record something a task produced: a file, PR, document or URL.",
        obj(
          Map.merge(agent_param(), %{
            "task" => @str,
            "uri" => @str,
            "kind" => @str,
            "summary" => @str
          }),
          ["task", "uri"]
        ),
        &artifact/2,
        write: true
      ),
      tool(
        "hive_message",
        "Message one agent (to: agent id), everyone with a skill (to: \"skill:rust\"), or everyone (to: \"*\").",
        obj(Map.merge(agent_param(), %{"to" => @str, "text" => @str}), ["to", "text"]),
        &message/2,
        write: true
      ),
      tool(
        "hive_inbox",
        "Your messages, open questions you could answer, and leases about to run out.",
        obj(Map.merge(agent_param(), %{"since" => Map.put(@int, "description", "ms timestamp")})),
        &inbox/2
      ),
      tool(
        "hive_heartbeat",
        "Tell the swarm you are still here, with an optional status line.",
        obj(Map.merge(agent_param(), %{"status" => @str})),
        &heartbeat/2,
        write: true
      ),
      tool(
        "hive_search",
        "Find tasks, goals, insights, questions and decisions by words.",
        obj(%{"text" => @str, "limit" => @int}, ["text"]),
        fn a, _ -> {:ok, %{results: Hive.search(a["text"], a["limit"] || 20)}} end
      ),
      tool(
        "hive_query",
        "Run a read-only Cypher query against the shared graph (Glider). Labels: HiveGoal, HiveTask, HiveClaim, HiveAgent, HiveInsight, HiveQuestion, HiveAnswer, HiveDecision, HiveNote, HiveArtifact, HiveMessage; plus Repo, Finding, Proposal, Attempt.",
        obj(%{"cypher" => @str}, ["cypher"]),
        &query/2
      )
    ]
  end

  defp tool(name, description, schema, handler, opts \\ []) do
    %{
      name: name,
      description: description,
      inputSchema: schema,
      annotations: %{readOnlyHint: !Keyword.get(opts, :write, false), openWorldHint: false},
      handler: handler
    }
  end

  # ===========================================================================
  # Handlers: (args, ctx) -> {:ok, map} | {:error, message}
  # ctx: %{agent: id | nil, session: id | nil, set_agent: fun}
  # ===========================================================================

  defp join(a, ctx) do
    with {:ok, agent} <-
           Hive.join(
             id: a["agent_id"],
             name: a["name"],
             skills: a["skills"] || [],
             kind: a["kind"] || "mcp",
             model: a["model"] || ""
           ) do
      ctx.set_agent.(agent.id)

      {:ok,
       %{
         agent: agent,
         board: Hive.digest(limit: 5),
         how_to_work: JidoSwarm.MCP.Prompts.worker_brief()
       }}
    end
  end

  defp next_task(a, ctx) do
    with {:ok, me} <- me(a, ctx) do
      opts = if a["skills"], do: [skills: a["skills"]], else: []

      case Hive.next_task(me, opts) do
        {:ok, %{task: t, context: ctx_md}} ->
          {:ok,
           %{claimed: true, task: task_view(t), lease_until: t.claim.lease_until, context: ctx_md}}

        :none ->
          {:ok,
           %{
             claimed: false,
             message:
               "Nothing open for you right now. Check hive_inbox for questions, or hive_board for work to add."
           }}
      end
    end
  end

  defp ranked(a, ctx) do
    with {:ok, me} <- me(a, ctx) do
      {:ok,
       %{
         tasks:
           me
           |> Hive.ranked()
           |> Enum.take(a["limit"] || 10)
           |> Enum.map(&Map.merge(task_view(&1), %{score: &1.score, why: &1.why}))
       }}
    end
  end

  defp context(a, ctx) do
    case Hive.context(a["task"], agent: ctx.agent, budget: a["budget"] || 12_000) do
      {:ok, pack} -> {:ok, %{task: task_view(pack.task), context: pack.markdown}}
      {:error, :no_such_task} -> {:error, "no such task: #{a["task"]}"}
    end
  end

  defp claim(a, ctx) do
    with {:ok, me} <- me(a, ctx),
         {:ok, c} <- Hive.claim(a["task"], me) |> explain() do
      {:ok, pack} = Hive.context(a["task"], agent: me)
      {:ok, %{claimed: true, lease_until: c.lease_until, context: pack.markdown}}
    end
  end

  defp progress(a, ctx),
    do: act(a, ctx, &Hive.progress(&1, a["task"], a["note"]), %{renewed: true})

  defp fail(a, ctx), do: act(a, ctx, &Hive.fail(&1, a["task"], a["reason"]), %{failed: true})

  defp handoff(a, ctx),
    do: act(a, ctx, &Hive.handoff(&1, a["task"], a["note"]), %{released: true})

  defp finish(a, ctx) do
    act(
      a,
      ctx,
      fn me ->
        Hive.finish(me, a["task"], a["summary"],
          insights: a["insights"] || [],
          artifacts: a["artifacts"] || [],
          decisions: a["decisions"] || []
        )
      end,
      %{done: true}
    )
  end

  defp add_goal(a, ctx) do
    creator = ctx.agent || a["agent_id"] || "unknown"

    with {:ok, key} <- Hive.add_goal(Map.put(a, "created_by", creator)) |> explain(),
         do: {:ok, %{goal: key}}
  end

  defp add_task(a, ctx) do
    creator = ctx.agent || a["agent_id"] || "unknown"

    with {:ok, key} <- Hive.add_task(Map.put(a, "created_by", creator)) |> explain(),
         do: {:ok, %{task: key}}
  end

  defp decompose(a, ctx) do
    with {:ok, me} <- me(a, ctx),
         {:ok, keys} <- Hive.decompose(a["task"], a["subtasks"], me) |> explain() do
      {:ok, %{subtasks: keys}}
    end
  end

  defp share(a, ctx) do
    with {:ok, me} <- me(a, ctx),
         {:ok, key} <- Hive.share(me, a) |> explain(),
         do: {:ok, %{insight: key}}
  end

  defp endorse(a, ctx),
    do: act(a, ctx, &Hive.endorse(&1, a["insight"], a["weight"] || 1), %{recorded: true})

  defp ask(a, ctx) do
    with {:ok, me} <- me(a, ctx),
         {:ok, key} <- Hive.ask(me, a) |> explain(),
         do: {:ok, %{question: key}}
  end

  defp answer(a, ctx) do
    with {:ok, me} <- me(a, ctx),
         {:ok, key} <- Hive.answer(me, a["question"], a["text"]) |> explain(),
         do: {:ok, %{answer: key}}
  end

  defp decide(a, ctx) do
    with {:ok, me} <- me(a, ctx),
         {:ok, key} <- Hive.decide(me, a) |> explain(),
         do: {:ok, %{decision: key}}
  end

  defp artifact(a, ctx) do
    with {:ok, me} <- me(a, ctx),
         {:ok, key} <- Hive.artifact(me, a["task"], a) |> explain(),
         do: {:ok, %{artifact: key}}
  end

  defp message(a, ctx) do
    with {:ok, me} <- me(a, ctx),
         {:ok, key} <- Hive.message(me, a["to"], a["text"]) |> explain(),
         do: {:ok, %{message: key}}
  end

  defp inbox(a, ctx) do
    with {:ok, me} <- me(a, ctx), do: {:ok, Hive.inbox(me, a["since"] || 0)}
  end

  defp heartbeat(a, ctx), do: act(a, ctx, &Hive.heartbeat(&1, a["status"]), %{ok: true})

  defp query(a, _ctx) do
    case Hive.read_query(a["cypher"]) do
      {:ok, r} -> {:ok, r}
      {:error, msg} -> {:error, msg}
    end
  end

  # ===========================================================================
  # Helpers
  # ===========================================================================

  defp me(a, ctx) do
    case a["agent_id"] || ctx.agent do
      nil -> {:error, "no agent: call hive_join first (or pass agent_id)"}
      id -> {:ok, id}
    end
  end

  defp act(a, ctx, fun, ok) do
    with {:ok, me} <- me(a, ctx) do
      case fun.(me) |> explain() do
        :ok -> {:ok, ok}
        {:ok, _} -> {:ok, ok}
        err -> err
      end
    end
  end

  defp explain({:error, {:held_by, who}}), do: {:error, "the task is held by #{who}"}

  defp explain({:error, :not_open}),
    do: {:error, "the task is done or split; it cannot be claimed"}

  defp explain({:error, :lost_race}),
    do: {:error, "another agent claimed it at the same moment; try hive_next_task"}

  defp explain({:error, :not_claimed}), do: {:error, "you do not hold that task (claim it first)"}
  defp explain({:error, :unknown_agent}), do: {:error, "unknown agent: call hive_join"}
  defp explain({:error, reason}) when is_binary(reason), do: {:error, reason}
  defp explain({:error, reason}), do: {:error, inspect(reason)}
  defp explain(other), do: other

  defp task_view(t) do
    Map.take(t, [
      :key,
      :title,
      :detail,
      :acceptance,
      :priority,
      :skills,
      :status,
      :goal,
      :parent,
      :depends_on,
      :subtasks,
      :attempts
    ])
  end

  @doc false
  def insight_words(text), do: Memory.words(text)
end
