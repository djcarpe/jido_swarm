defmodule JidoSwarm.LLM do
  @moduledoc """
  The model interface the swarm talks to.

  One provider-neutral shape in, one provider-neutral shape out. Providers
  translate at the edge, so a worker never knows whether it is talking to a 4B
  model on the workstation or to Claude.

  ## Providers

  | Module | Backing |
  |---|---|
  | `JidoSwarm.LLM.Ollama` | the local Ollama server, over its OpenAI-compatible `/v1` API |
  | `JidoSwarm.LLM.Anthropic` | the Claude Messages API |

  Selected per call or from config:

      config :jido_swarm, JidoSwarm.LLM,
        provider: JidoSwarm.LLM.Ollama,
        ollama: [base_url: "http://127.0.0.1:11434", model: "qwen3:4b-instruct"],
        anthropic: [api_key: nil, model: "claude-opus-5"]

  ## Messages

  A message is a map with `:role` and `:content`:

      %{role: :system,    content: "You are a careful Elixir engineer."}
      %{role: :user,      content: "Propose a feature for Jido."}
      %{role: :assistant, content: "...", tool_calls: [...], raw: <provider blocks>}
      %{role: :tool,      content: "...", tool_call_id: "toolu_01..."}

  `:raw` carries the provider's own representation of an assistant turn. It
  exists because Claude requires thinking and tool-use blocks to be echoed back
  *unchanged* on the next request — reconstructing them from the normalized
  fields would drop the signature and invalidate the turn. Providers that have
  no such requirement ignore it.

  ## Tools

      %{
        name: "read_file",
        description: "Read a file from a repository",
        schema: %{
          "type" => "object",
          "properties" => %{"path" => %{"type" => "string"}},
          "required" => ["path"]
        }
      }

  ## Result

      %{
        text: "…",
        tool_calls: [%{id: "…", name: "read_file", arguments: %{"path" => "mix.exs"}}],
        stop: :end_turn | :tool_use | :max_tokens | :refusal,
        usage: %{input_tokens: 1, output_tokens: 2},
        raw: <provider blocks>,
        model: "qwen3:4b-instruct"
      }
  """

  @type role :: :system | :user | :assistant | :tool
  @type message :: %{
          required(:role) => role(),
          required(:content) => String.t(),
          optional(:tool_calls) => [tool_call()],
          optional(:tool_call_id) => String.t(),
          optional(:raw) => term()
        }
  @type tool_call :: %{id: String.t(), name: String.t(), arguments: map()}
  @type tool :: %{name: String.t(), description: String.t(), schema: map()}
  @type result :: %{
          text: String.t(),
          tool_calls: [tool_call()],
          stop: atom(),
          usage: map(),
          raw: term(),
          model: String.t()
        }

  @doc """
  Sends a conversation to the model.

  ## Options

  * `:provider` — override the configured provider module.
  * `:model` — override the provider's default model.
  * `:tools` — tool definitions the model may call.
  * `:max_tokens` — output cap.
  * `:temperature` — sampling, where the provider supports it.
  * `:timeout` — request timeout in ms.
  """
  @callback chat([message()], keyword()) :: {:ok, result()} | {:error, term()}

  @doc "Is this provider configured well enough to be used?"
  @callback ready?() :: boolean()

  @doc "A human-readable note on why the provider is not ready."
  @callback readiness_hint() :: String.t()

  @doc """
  Sends a conversation to the configured provider.
  """
  @spec chat([message()], keyword()) :: {:ok, result()} | {:error, term()}
  def chat(messages, opts \\ []) do
    {provider, opts} = Keyword.pop_lazy(opts, :provider, &provider/0)
    provider.chat(messages, opts)
  end

  @doc """
  The configured provider module.

  Defaults to Ollama, so a checkout with no API key anywhere still runs.
  """
  @spec provider() :: module()
  def provider do
    config() |> Keyword.get(:provider, JidoSwarm.LLM.Ollama)
  end

  @doc "Configuration for `JidoSwarm.LLM`."
  @spec config() :: keyword()
  def config, do: Application.get_env(:jido_swarm, __MODULE__, [])

  @doc "Configuration for one provider, by its config key."
  @spec provider_config(atom()) :: keyword()
  def provider_config(key), do: config() |> Keyword.get(key, [])

  @doc """
  Every known provider and whether it is usable right now.

  Surfaced in the UI so it is obvious which model the swarm is actually on, and
  why the other one is not available.
  """
  @spec providers() :: [
          %{module: module(), name: String.t(), ready?: boolean(), hint: String.t()}
        ]
  def providers do
    for mod <- [JidoSwarm.LLM.Ollama, JidoSwarm.LLM.Anthropic] do
      %{
        module: mod,
        name: mod |> Module.split() |> List.last(),
        ready?: mod.ready?(),
        hint: mod.readiness_hint(),
        active?: mod == provider()
      }
    end
  end

  @doc """
  Builds a normalized assistant message from a result, ready to append to the
  conversation before the tool results.
  """
  @spec assistant_message(result()) :: message()
  def assistant_message(result) do
    %{
      role: :assistant,
      content: result.text,
      tool_calls: result.tool_calls,
      raw: result.raw
    }
  end

  @doc "Builds a tool-result message for a call the swarm has executed."
  @spec tool_message(tool_call(), String.t()) :: message()
  def tool_message(%{id: id}, content) when is_binary(content) do
    %{role: :tool, content: content, tool_call_id: id}
  end
end
