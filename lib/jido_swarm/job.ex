defmodule JidoSwarm.Job do
  @moduledoc """
  A unit of work for the swarm.

  Jobs are the thing the queue holds, the autoscaler counts, and a worker
  executes. They are deliberately coarse — one job is one meaningful step a
  worker can finish and write into the knowledge graph.

  | Type | What a worker does |
  |---|---|
  | `:survey` | read a repository and record findings |
  | `:propose` | turn findings into a concrete feature proposal |
  | `:implement` | implement a proposal on a branch, run the tests, open a PR |
  | `:chat` | answer the operator, grounded in the knowledge graph |
  | `:hive` | work a task the worker claimed from the Hive board itself (`payload.task`) |

  `:chat` carries a `reply_to` pid so the LiveView that asked gets the answer
  directly; the other types report only into the graph, and the UI reacts to the
  mesh.

  A job may name its `model` (`PROVIDER/MODEL` on the ragentic gateway, a tag
  on Ollama, an id on Anthropic); without one the provider's default answers.
  """

  @enforce_keys [:id, :type]
  defstruct [
    :id,
    :type,
    :repo,
    :proposal_key,
    :prompt,
    :reply_to,
    :worker,
    :error,
    :model,
    status: :pending,
    payload: %{},
    enqueued_at: nil,
    started_at: nil,
    finished_at: nil
  ]

  @type type :: :survey | :propose | :implement | :chat | :hive
  @type status :: :pending | :running | :done | :failed

  @type t :: %__MODULE__{
          id: String.t(),
          type: type(),
          repo: String.t() | nil,
          proposal_key: String.t() | nil,
          prompt: String.t() | nil,
          reply_to: pid() | nil,
          worker: String.t() | nil,
          error: term(),
          model: String.t() | nil,
          status: status(),
          payload: map(),
          enqueued_at: integer() | nil,
          started_at: integer() | nil,
          finished_at: integer() | nil
        }

  @doc "Builds a job."
  @spec new(type(), keyword()) :: t()
  def new(type, opts \\ []) when type in [:survey, :propose, :implement, :chat, :hive] do
    %__MODULE__{
      id: opts[:id] || generate_id(),
      type: type,
      repo: opts[:repo],
      proposal_key: opts[:proposal_key],
      prompt: opts[:prompt],
      reply_to: opts[:reply_to],
      model: opts[:model],
      payload: opts[:payload] || %{},
      enqueued_at: System.system_time(:millisecond)
    }
  end

  @doc "A short human label, for the activity feed."
  @spec label(t()) :: String.t()
  def label(%__MODULE__{type: :survey, repo: repo}), do: "survey #{repo}"
  def label(%__MODULE__{type: :propose, repo: repo}), do: "propose for #{repo}"

  def label(%__MODULE__{type: :implement, proposal_key: key}),
    do: "implement #{String.replace_prefix(key || "", "proposal:", "")}"

  def label(%__MODULE__{type: :chat, prompt: prompt}), do: "chat: #{truncate(prompt, 40)}"

  def label(%__MODULE__{type: :hive, payload: payload}),
    do: "hive: #{truncate(Map.get(payload, :title) || Map.get(payload, :task) || "", 40)}"

  defp truncate(nil, _), do: ""

  defp truncate(text, max) do
    if String.length(text) > max, do: String.slice(text, 0, max) <> "…", else: text
  end

  defp generate_id do
    "job_" <> (:crypto.strong_rand_bytes(8) |> Base.encode32(case: :lower, padding: false))
  end
end
