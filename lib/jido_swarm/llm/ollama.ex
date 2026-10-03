defmodule JidoSwarm.LLM.Ollama do
  @moduledoc """
  `JidoSwarm.LLM` against the local Ollama server.

  ## Why the native API and not the OpenAI-compatible one

  Ollama serves both. The OpenAI shape at `/v1/chat/completions` is the more
  familiar one, and it was the first thing this used — but it gives no way to
  set the context window, and Ollama defaults to **4096 tokens regardless of
  what the model supports**. `qwen3:4b-instruct` advertises a 262144-token
  context and still rejected a 5262-token prompt with
  `exceed_context_size_error`.

  The native `/api/chat` takes `options.num_ctx`, so the window is a decision
  rather than a surprise. That is worth more than protocol familiarity when the
  whole design leans on feeding repository files to the model.

  ## Configuration

      config :jido_swarm, JidoSwarm.LLM,
        ollama: [
          base_url: "http://127.0.0.1:11434",
          model: "qwen3:4b-instruct",
          num_ctx: 16_384,
          timeout: 180_000
        ]

  In the cluster the base URL points at the `ollama-external` Service, which
  forwards to the workstation — Ollama must be bound to the LAN
  (`OLLAMA_HOST=0.0.0.0:11434`) for that to resolve.

  ## Tool calls from small models

  A 4B model's tool calls are frequently malformed — arguments arriving as a
  JSON *string* rather than an object is the usual one — so
  `decode_arguments/1` is forgiving rather than letting a worker crash on a bad
  call.
  """

  @behaviour JidoSwarm.LLM

  require Logger

  @default_base_url "http://127.0.0.1:11434"
  @default_model "qwen3:4b-instruct"
  @default_timeout 180_000
  @default_num_ctx 16_384

  @impl true
  def ready? do
    case Req.get(url("/api/tags"), receive_timeout: 5_000, retry: false) do
      {:ok, %{status: 200}} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  @impl true
  def readiness_hint do
    "Expected an Ollama server at #{base_url()}. Start it with `ollama serve`, " <>
      "and for in-cluster access set OLLAMA_HOST=0.0.0.0:11434."
  end

  @doc "Models the server currently has pulled."
  @spec models() :: {:ok, [String.t()]} | {:error, term()}
  @impl true
  def models do
    case Req.get(url("/api/tags"), receive_timeout: 10_000) do
      {:ok, %{status: 200, body: %{"models" => models}}} ->
        {:ok, Enum.map(models, & &1["name"])}

      {:ok, %{status: status, body: body}} ->
        {:error, {:http, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def chat(messages, opts \\ []) do
    model = opts[:model] || model()

    body =
      %{
        "model" => model,
        "messages" => Enum.map(messages, &encode_message/1),
        "stream" => false,
        "options" => options(opts)
      }
      |> maybe_put("tools", encode_tools(opts[:tools]))

    request =
      Req.new(
        url: url("/api/chat"),
        json: body,
        receive_timeout: opts[:timeout] || timeout(),
        retry: :transient,
        max_retries: 2
      )

    case Req.post(request) do
      {:ok, %{status: 200, body: response}} -> {:ok, decode_response(response, model)}
      {:ok, %{status: status, body: body}} -> {:error, {:http, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  # `num_predict` is Ollama's name for the output cap; `num_ctx` is the whole
  # window, prompt included, and is the one that actually bites.
  defp options(opts) do
    %{"num_ctx" => opts[:num_ctx] || num_ctx()}
    |> maybe_put("num_predict", opts[:max_tokens])
    |> maybe_put("temperature", opts[:temperature])
  end

  # ===========================================================================
  # Encoding
  # ===========================================================================

  defp encode_message(%{role: :tool} = message) do
    %{"role" => "tool", "content" => message.content}
  end

  defp encode_message(%{role: :assistant} = message) do
    base = %{"role" => "assistant", "content" => message.content || ""}

    case Map.get(message, :tool_calls) do
      calls when is_list(calls) and calls != [] ->
        Map.put(base, "tool_calls", Enum.map(calls, &encode_tool_call/1))

      _ ->
        base
    end
  end

  defp encode_message(message) do
    %{"role" => to_string(message.role), "content" => message.content}
  end

  defp encode_tool_call(call) do
    %{"function" => %{"name" => call.name, "arguments" => call.arguments}}
  end

  defp encode_tools(nil), do: nil
  defp encode_tools([]), do: nil

  defp encode_tools(tools) do
    Enum.map(tools, fn tool ->
      %{
        "type" => "function",
        "function" => %{
          "name" => tool.name,
          "description" => tool.description,
          "parameters" => tool.schema
        }
      }
    end)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # ===========================================================================
  # Decoding
  # ===========================================================================

  defp decode_response(response, model) do
    message = Map.get(response, "message", %{})

    %{
      text: Map.get(message, "content") || "",
      tool_calls: decode_tool_calls(Map.get(message, "tool_calls")),
      stop: decode_stop(Map.get(response, "done_reason")),
      usage: %{
        input_tokens: Map.get(response, "prompt_eval_count", 0),
        output_tokens: Map.get(response, "eval_count", 0)
      },
      raw: message,
      model: Map.get(response, "model", model)
    }
  end

  defp decode_tool_calls(nil), do: []

  defp decode_tool_calls(calls) when is_list(calls) do
    Enum.map(calls, fn call ->
      function = Map.get(call, "function", %{})

      %{
        id: Map.get(call, "id") || generate_call_id(),
        name: Map.get(function, "name", ""),
        arguments: decode_arguments(Map.get(function, "arguments"))
      }
    end)
  end

  defp decode_tool_calls(_), do: []

  # The native API sends arguments as an object, but small models sometimes
  # produce a JSON string, and sometimes a string that is not valid JSON at all.
  # None of those should take down the worker that asked for the call.
  defp decode_arguments(nil), do: %{}
  defp decode_arguments(args) when is_map(args), do: args

  defp decode_arguments(args) when is_binary(args) do
    case JSON.decode(args) do
      {:ok, decoded} when is_map(decoded) ->
        decoded

      _ ->
        Logger.warning("ollama: tool arguments were not decodable JSON: #{inspect(args)}")
        %{"_raw" => args}
    end
  end

  defp decode_arguments(_), do: %{}

  defp decode_stop("stop"), do: :end_turn
  defp decode_stop("length"), do: :max_tokens
  defp decode_stop(other) when is_binary(other), do: String.to_atom(other)
  defp decode_stop(_), do: :end_turn

  defp generate_call_id,
    do: "call_" <> (:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower))

  # ===========================================================================
  # Config
  # ===========================================================================

  @doc "The configured base URL."
  @spec base_url() :: String.t()
  def base_url do
    JidoSwarm.LLM.provider_config(:ollama)
    |> Keyword.get(:base_url, @default_base_url)
    |> String.trim_trailing("/")
  end

  @doc "The configured default model."
  @spec model() :: String.t()
  @impl true
  def model do
    JidoSwarm.LLM.provider_config(:ollama) |> Keyword.get(:model, @default_model)
  end

  @doc "The context window requested from the server."
  @spec num_ctx() :: pos_integer()
  def num_ctx do
    JidoSwarm.LLM.provider_config(:ollama) |> Keyword.get(:num_ctx, @default_num_ctx)
  end

  defp timeout do
    JidoSwarm.LLM.provider_config(:ollama) |> Keyword.get(:timeout, @default_timeout)
  end

  defp url(path), do: base_url() <> path
end
