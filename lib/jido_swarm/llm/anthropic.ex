defmodule JidoSwarm.LLM.Anthropic do
  @moduledoc """
  `JidoSwarm.LLM` against the Claude Messages API.

  Elixir has no official Anthropic SDK, so this speaks the REST API directly —
  `POST /v1/messages`, `x-api-key`, `anthropic-version: 2023-06-01`.

  ## Configuration

      config :jido_swarm, JidoSwarm.LLM,
        provider: JidoSwarm.LLM.Anthropic,
        anthropic: [
          api_key: System.get_env("ANTHROPIC_API_KEY"),
          model: "claude-opus-5"
        ]

  Until a key is present, `ready?/0` is false and the swarm stays on the local
  model. Nothing else needs to change to switch over: set the key and flip
  `:provider`.

  ## Choices this makes, and why

  * **Adaptive thinking is on** (`thinking: {type: "adaptive"}`). Proposing and
    implementing a feature is exactly the kind of work it helps. `budget_tokens`
    is *rejected* on Opus 5 — it belongs to an older API.
  * **Assistant turns are echoed back verbatim** from `result.raw`. Thinking
    blocks carry a signature; rebuilding them from text would invalidate the
    turn, so the raw content blocks are replayed unchanged.
  * **Refusals are a value, not an error.** A policy decline arrives as HTTP 200
    with `stop_reason: "refusal"`. Server-side fallbacks are enabled by default,
    so a decline is re-run on a fallback model inside the same call rather than
    silently returning nothing.
  * **Effort** goes in `output_config`, not at the top level.
  """

  @behaviour JidoSwarm.LLM

  @api_url "https://api.anthropic.com/v1/messages"
  @api_version "2023-06-01"
  @fallback_beta "server-side-fallback-2026-07-01"
  @default_model "claude-opus-5"
  @default_max_tokens 16_000
  @default_timeout 600_000

  @impl true
  def ready?, do: is_binary(api_key()) and api_key() != ""

  @impl true
  def readiness_hint do
    "Set ANTHROPIC_API_KEY (or :api_key under config :jido_swarm, JidoSwarm.LLM, :anthropic) " <>
      "and set :provider to JidoSwarm.LLM.Anthropic."
  end

  @impl true
  def chat(messages, opts \\ []) do
    if ready?() do
      do_chat(messages, opts)
    else
      {:error, {:not_configured, readiness_hint()}}
    end
  end

  defp do_chat(messages, opts) do
    {system, turns} = split_system(messages)

    body =
      %{
        "model" => opts[:model] || model(),
        "max_tokens" => opts[:max_tokens] || @default_max_tokens,
        "messages" => encode_turns(turns),
        "thinking" => %{"type" => "adaptive"},
        # A policy decline is re-run on a fallback model inside the same call.
        "fallbacks" => "default"
      }
      |> maybe_put("system", system)
      |> maybe_put("tools", encode_tools(opts[:tools]))
      |> maybe_put("output_config", encode_output_config(opts[:effort]))

    request =
      Req.new(
        url: @api_url,
        json: body,
        headers: [
          {"x-api-key", api_key()},
          {"anthropic-version", @api_version},
          {"anthropic-beta", @fallback_beta}
        ],
        receive_timeout: opts[:timeout] || timeout(),
        retry: :transient,
        max_retries: 2
      )

    case Req.post(request) do
      {:ok, %{status: 200, body: response}} -> {:ok, decode_response(response)}
      {:ok, %{status: status, body: body}} -> {:error, {:http, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  # ===========================================================================
  # Encoding
  # ===========================================================================

  # Claude takes the system prompt as a top-level field, not a message.
  defp split_system(messages) do
    {systems, turns} = Enum.split_with(messages, &(&1.role == :system))
    system = systems |> Enum.map_join("\n\n", & &1.content) |> presence()
    {system, turns}
  end

  defp presence(""), do: nil
  defp presence(value), do: value

  defp encode_turns(turns) do
    turns
    |> Enum.map(&encode_turn/1)
    |> merge_tool_results()
  end

  # An assistant turn is replayed from the provider's own blocks when we have
  # them — thinking blocks are signed, and a reconstructed one is rejected.
  defp encode_turn(%{role: :assistant, raw: raw}) when is_list(raw) and raw != [] do
    %{"role" => "assistant", "content" => raw}
  end

  defp encode_turn(%{role: :assistant} = message) do
    text_block = if message.content in [nil, ""], do: [], else: [text_block(message.content)]

    tool_blocks =
      message
      |> Map.get(:tool_calls, [])
      |> Enum.map(fn call ->
        %{"type" => "tool_use", "id" => call.id, "name" => call.name, "input" => call.arguments}
      end)

    %{"role" => "assistant", "content" => text_block ++ tool_blocks}
  end

  defp encode_turn(%{role: :tool} = message) do
    %{
      "role" => "user",
      "content" => [
        %{
          "type" => "tool_result",
          "tool_use_id" => message.tool_call_id,
          "content" => message.content
        }
      ]
    }
  end

  defp encode_turn(message) do
    %{"role" => "user", "content" => [text_block(message.content)]}
  end

  defp text_block(text), do: %{"type" => "text", "text" => text}

  # Every tool_result for one assistant turn must arrive in a *single* user
  # message. Splitting them across messages is accepted but teaches the model to
  # stop making parallel calls, so consecutive tool results are merged here.
  defp merge_tool_results(turns) do
    turns
    |> Enum.chunk_by(&tool_result_turn?/1)
    |> Enum.flat_map(fn chunk ->
      if chunk |> List.first() |> tool_result_turn?() do
        [%{"role" => "user", "content" => Enum.flat_map(chunk, & &1["content"])}]
      else
        chunk
      end
    end)
  end

  defp tool_result_turn?(%{"role" => "user", "content" => [%{"type" => "tool_result"} | _]}),
    do: true

  defp tool_result_turn?(_), do: false

  defp encode_tools(nil), do: nil
  defp encode_tools([]), do: nil

  defp encode_tools(tools) do
    Enum.map(tools, fn tool ->
      %{
        "name" => tool.name,
        "description" => tool.description,
        "input_schema" => tool.schema
      }
    end)
  end

  defp encode_output_config(nil), do: nil
  defp encode_output_config(effort), do: %{"effort" => to_string(effort)}

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # ===========================================================================
  # Decoding
  # ===========================================================================

  defp decode_response(response) do
    content = Map.get(response, "content", [])
    usage = Map.get(response, "usage", %{})

    %{
      text: content |> Enum.filter(&(&1["type"] == "text")) |> Enum.map_join("", & &1["text"]),
      tool_calls:
        content
        |> Enum.filter(&(&1["type"] == "tool_use"))
        |> Enum.map(fn block ->
          %{
            id: block["id"],
            name: block["name"],
            arguments: block["input"] || %{}
          }
        end),
      stop: decode_stop(Map.get(response, "stop_reason")),
      usage: %{
        input_tokens: Map.get(usage, "input_tokens", 0),
        output_tokens: Map.get(usage, "output_tokens", 0)
      },
      # Kept whole so the next request can replay it unchanged.
      raw: content,
      model: Map.get(response, "model", model())
    }
  end

  defp decode_stop("end_turn"), do: :end_turn
  defp decode_stop("tool_use"), do: :tool_use
  defp decode_stop("max_tokens"), do: :max_tokens
  defp decode_stop("refusal"), do: :refusal
  defp decode_stop("pause_turn"), do: :pause_turn
  defp decode_stop(other) when is_binary(other), do: String.to_atom(other)
  defp decode_stop(_), do: :end_turn

  # ===========================================================================
  # Config
  # ===========================================================================

  @doc "The configured API key, if any."
  @spec api_key() :: String.t() | nil
  def api_key do
    JidoSwarm.LLM.provider_config(:anthropic)
    |> Keyword.get(:api_key)
    |> case do
      nil -> System.get_env("ANTHROPIC_API_KEY")
      key -> key
    end
  end

  @doc "The configured default model."
  @spec model() :: String.t()
  def model do
    JidoSwarm.LLM.provider_config(:anthropic) |> Keyword.get(:model, @default_model)
  end

  defp timeout do
    JidoSwarm.LLM.provider_config(:anthropic) |> Keyword.get(:timeout, @default_timeout)
  end
end
