defmodule JidoSwarm.LLM.Ragentic do
  @moduledoc """
  `JidoSwarm.LLM` through ragentic's model gateway.

  ragentic keeps the organization's model providers — a laptop's Ollama
  reached over a relay, DeepSeek, OpenAI, Anthropic, a GPU box — registered
  at runtime as `ModelProvider` manifests, credentials included, and serves
  all of them as OpenAI chat completions at `/v1/chat/completions`. This
  provider points the swarm at that one endpoint. A model is named
  `PROVIDER/MODEL` (`dj-laptop/qwen3:4b-instruct`, `deepseek/deepseek-chat`),
  or a bare `PROVIDER` for its default; registering a new provider in
  ragentic is all it takes for every swarm pod to use it — no key in the
  swarm, no restart, and any pod of either cluster answers any provider.

  ## Configuration

      config :jido_swarm, JidoSwarm.LLM,
        provider: JidoSwarm.LLM.Ragentic,
        ragentic: [
          base_url: "https://ragentic.home",       # RAGENTIC_URL
          token: "ragentic_…",                     # RAGENTIC_TOKEN: an API key with the api scope
          model: "dj-laptop/qwen3:4b-instruct",    # RAGENTIC_MODEL (see `ragentic model ls`, or GET /v1/models)
          cacert: "/etc/ssl/homelab-root-ca.pem",  # RAGENTIC_CACERT: the server's private CA, if any
          timeout: 300_000
        ]

  The gateway answers whole (no streaming) and never retries a completion:
  a retried five-minute generation is worse than a reported failure.
  """

  @behaviour JidoSwarm.LLM

  require Logger

  @default_timeout 300_000

  @impl true
  def ready?, do: configured?() and match?({:ok, _}, models())

  @impl true
  def readiness_hint do
    cond do
      is_nil(base_url()) ->
        "Set RAGENTIC_URL to the ragentic server (https://ragentic.home)."

      is_nil(token()) ->
        "Set RAGENTIC_TOKEN to a ragentic API key with the api scope."

      is_nil(model()) ->
        "Set RAGENTIC_MODEL to PROVIDER/MODEL — GET /v1/models or `ragentic model ls` lists them."

      true ->
        "Expected ragentic's gateway at #{base_url()}/v1: is the server up, and the token still valid?"
    end
  end

  @doc "Every model the organization registered in ragentic, as PROVIDER/MODEL."
  @impl true
  @spec models() :: {:ok, [String.t()]} | {:error, term()}
  def models do
    if configured?() do
      case Req.get(request("/v1/models", receive_timeout: 10_000, retry: false)) do
        {:ok, %{status: 200, body: %{"data" => data}}} -> {:ok, Enum.map(data, & &1["id"])}
        {:ok, %{status: status, body: body}} -> {:error, {:http, status, body}}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :not_configured}
    end
  rescue
    e -> {:error, e}
  end

  @impl true
  def chat(messages, opts \\ []) do
    model = opts[:model] || model()

    body =
      %{"model" => model, "messages" => Enum.map(messages, &encode_message/1), "stream" => false}
      |> maybe_put("max_tokens", opts[:max_tokens])
      |> maybe_put("temperature", opts[:temperature])
      |> maybe_put("tools", encode_tools(opts[:tools]))

    request =
      request("/v1/chat/completions",
        json: body,
        receive_timeout: opts[:timeout] || timeout(),
        retry: false
      )

    case Req.post(request) do
      {:ok,
       %{status: 200, body: %{"choices" => [%{"message" => message} = choice | _]} = response}} ->
        {:ok, decode(message, choice, response, model)}

      {:ok, %{status: status, body: body}} ->
        {:error, {:http, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ===========================================================================
  # Encoding: the OpenAI shape
  # ===========================================================================

  defp encode_message(%{role: :tool} = message),
    do: %{"role" => "tool", "tool_call_id" => message.tool_call_id, "content" => message.content}

  defp encode_message(%{role: :assistant} = message) do
    base = %{"role" => "assistant", "content" => message.content || ""}

    case Map.get(message, :tool_calls) do
      calls when is_list(calls) and calls != [] ->
        Map.put(base, "tool_calls", Enum.map(calls, &encode_tool_call/1))

      _ ->
        base
    end
  end

  defp encode_message(message),
    do: %{"role" => to_string(message.role), "content" => message.content}

  defp encode_tool_call(call) do
    %{
      "id" => call.id,
      "type" => "function",
      "function" => %{"name" => call.name, "arguments" => JSON.encode!(call.arguments || %{})}
    }
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

  defp decode(message, choice, response, model) do
    calls = decode_tool_calls(message["tool_calls"])

    %{
      text: message["content"] || "",
      tool_calls: calls,
      stop: decode_stop(choice["finish_reason"], calls),
      usage: %{
        input_tokens: get_in(response, ["usage", "prompt_tokens"]) || 0,
        output_tokens: get_in(response, ["usage", "completion_tokens"]) || 0
      },
      raw: message,
      model: response["model"] || model
    }
  end

  defp decode_tool_calls(calls) when is_list(calls) do
    Enum.map(calls, fn call ->
      function = call["function"] || %{}

      %{
        id:
          call["id"] || "call_" <> (:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)),
        name: function["name"] || "",
        arguments: decode_arguments(function["arguments"])
      }
    end)
  end

  defp decode_tool_calls(_), do: []

  # Small models behind the gateway produce the same malformed arguments the
  # Ollama provider forgives; a bad call is the model's problem, not the worker's.
  defp decode_arguments(nil), do: %{}
  defp decode_arguments(args) when is_map(args), do: args

  defp decode_arguments(args) when is_binary(args) do
    case JSON.decode(args) do
      {:ok, decoded} when is_map(decoded) ->
        decoded

      _ ->
        Logger.warning("ragentic: tool arguments were not decodable JSON: #{inspect(args)}")
        %{"_raw" => args}
    end
  end

  defp decode_arguments(_), do: %{}

  defp decode_stop(_reason, [_ | _]), do: :tool_use
  defp decode_stop("tool_calls", _), do: :tool_use
  defp decode_stop("length", _), do: :max_tokens
  defp decode_stop("content_filter", _), do: :refusal
  defp decode_stop(_, _), do: :end_turn

  # ===========================================================================
  # Config
  # ===========================================================================

  defp request(path, extra) do
    Req.new(
      [url: base_url() <> path, headers: [{"authorization", "Bearer " <> (token() || "")}]] ++
        tls() ++ extra ++ Keyword.get(config(), :req_options, [])
    )
  end

  defp tls do
    case config()[:cacert] do
      path when is_binary(path) and path != "" ->
        [connect_options: [transport_opts: [cacertfile: String.to_charlist(path)]]]

      _ ->
        []
    end
  end

  defp configured?, do: not is_nil(base_url()) and not is_nil(token()) and not is_nil(model())

  @doc "The ragentic server, without a trailing slash (nil when unset)."
  @spec base_url() :: String.t() | nil
  def base_url do
    case config()[:base_url] do
      url when is_binary(url) and url != "" -> String.trim_trailing(url, "/")
      _ -> nil
    end
  end

  @doc "The configured default model, as PROVIDER/MODEL (nil when unset)."
  @impl true
  @spec model() :: String.t() | nil
  def model do
    case config()[:model] do
      m when is_binary(m) and m != "" -> m
      _ -> nil
    end
  end

  defp token do
    case config()[:token] do
      t when is_binary(t) and t != "" -> t
      _ -> nil
    end
  end

  defp timeout, do: config()[:timeout] || @default_timeout

  defp config, do: JidoSwarm.LLM.provider_config(:ragentic)
end
