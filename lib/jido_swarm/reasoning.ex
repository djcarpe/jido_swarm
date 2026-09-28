defmodule JidoSwarm.Reasoning do
  @moduledoc """
  Prompting helpers shared by the swarm's actions.

  ## Why structured single-shot prompts rather than tool loops

  The swarm's default model is a 4B local model. Multi-turn tool loops against
  a model that size fail in ways that are tedious to recover from — malformed
  arguments, forgotten tool ids, loops that never terminate. Asking for one
  JSON document instead puts all the fragility in one place, where
  `extract_json/1` can be forgiving about it.

  The same prompts work unchanged against Claude, which simply produces better
  answers to them. That is the point of keeping the shape provider-neutral.
  """

  require Logger

  alias JidoSwarm.LLM

  @doc """
  Asks the model for a JSON document and parses it leniently.

  `expect` is `:object` or `:list`, and decides what a bare top-level value is
  coerced into. Returns `{:error, {:unparseable, text}}` when nothing
  JSON-shaped can be found, so the caller can record the raw answer rather than
  discard it.
  """
  @spec ask_json([LLM.message()], :object | :list, keyword()) ::
          {:ok, term(), LLM.result()} | {:error, term()}
  def ask_json(messages, expect, opts \\ []) do
    case LLM.chat(messages, opts) do
      {:ok, result} ->
        case extract_json(result.text, expect) do
          {:ok, value} -> {:ok, value, result}
          :error -> {:error, {:unparseable, result.text}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Like `ask_json/3`, but the model may call tools on the way to its answer.

  Each round sends the conversation with `tools`; if the model calls any,
  `executor.(name, arguments)` runs each one and its text goes back as a tool
  result, and the loop continues. It ends when the model answers without
  calling a tool, or after `:max_rounds` (default #{12}) rounds — a model
  that reads forever is cut off and asked for its answer from what it has.
  Returns the JSON in the final answer, and the last result.
  """
  @spec ask_json_with_tools(
          [LLM.message()],
          :object | :list,
          [LLM.tool()],
          (String.t(), map() -> String.t()),
          keyword()
        ) :: {:ok, term(), LLM.result()} | {:error, term()}
  def ask_json_with_tools(messages, expect, tools, executor, opts \\ []) do
    {max_rounds, opts} = Keyword.pop(opts, :max_rounds, 12)
    loop_tools(messages, expect, tools, executor, opts, max_rounds)
  end

  defp loop_tools(messages, expect, tools, executor, opts, rounds_left) do
    tool_opts = if rounds_left > 0, do: Keyword.put(opts, :tools, tools), else: opts

    case LLM.chat(messages, tool_opts) do
      {:ok, %{tool_calls: [_ | _] = calls} = result} when rounds_left > 0 ->
        results =
          Enum.map(calls, fn call ->
            LLM.tool_message(call, executor.(call.name, call.arguments || %{}))
          end)

        next = messages ++ [LLM.assistant_message(result)] ++ results

        # The last round goes out without tools, so the model must answer.
        next =
          if rounds_left == 1,
            do:
              next ++
                [
                  %{
                    role: :user,
                    content:
                      "You have used every tool call available. Answer now with the JSON object from what you have read."
                  }
                ],
            else: next

        loop_tools(next, expect, tools, executor, opts, rounds_left - 1)

      {:ok, result} ->
        case extract_json(result.text || "", expect) do
          {:ok, value} -> {:ok, value, result}
          :error -> {:error, {:unparseable, result.text}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Pulls the first JSON value out of model output.

  Models wrap JSON in prose, in ```json fences, or in both. This tries, in
  order: the whole string, each fenced block, then the first balanced `{...}`
  or `[...]` span. Balancing is brace-counting that respects strings and
  escapes, so a `}` inside a string value does not end the span early.

      iex> JidoSwarm.Reasoning.extract_json(~s|Here you go: {"a": 1} hope that helps|, :object)
      {:ok, %{"a" => 1}}

      iex> JidoSwarm.Reasoning.extract_json("no json here", :object)
      :error
  """
  @spec extract_json(String.t(), :object | :list) :: {:ok, term()} | :error
  def extract_json(text, expect \\ :object) when is_binary(text) do
    candidates = [text] ++ fenced_blocks(text) ++ balanced_spans(text)

    Enum.find_value(candidates, :error, fn candidate ->
      case JSON.decode(String.trim(candidate)) do
        {:ok, value} -> coerce(value, expect)
        _ -> nil
      end
    end)
  end

  defp coerce(value, :object) when is_map(value), do: {:ok, value}
  defp coerce([first | _], :object) when is_map(first), do: {:ok, first}
  defp coerce(value, :list) when is_list(value), do: {:ok, value}
  defp coerce(value, :list) when is_map(value), do: {:ok, [value]}
  defp coerce(_, _), do: nil

  defp fenced_blocks(text) do
    ~r/```(?:json)?\s*(.+?)```/s
    |> Regex.scan(text, capture: :all_but_first)
    |> Enum.map(fn [block] -> block end)
  end

  # Brace-matching that tracks string state, so punctuation inside a string
  # value cannot close the span early.
  defp balanced_spans(text) do
    graphemes = String.graphemes(text)

    for {open, close} <- [{"{", "}"}, {"[", "]"}],
        span = balanced_span(graphemes, open, close),
        not is_nil(span),
        do: span
  end

  defp balanced_span(graphemes, open, close) do
    case Enum.find_index(graphemes, &(&1 == open)) do
      nil ->
        nil

      start ->
        graphemes
        |> Enum.drop(start)
        |> scan_balanced(open, close)
    end
  end

  defp scan_balanced(graphemes, open, close) do
    {acc, depth, _in_string?, _escaped?} =
      Enum.reduce_while(graphemes, {[], 0, false, false}, fn char,
                                                             {acc, depth, in_string?, escaped?} ->
        acc = [char | acc]

        cond do
          escaped? ->
            {:cont, {acc, depth, in_string?, false}}

          char == "\\" and in_string? ->
            {:cont, {acc, depth, in_string?, true}}

          char == ~s(") ->
            {:cont, {acc, depth, not in_string?, false}}

          in_string? ->
            {:cont, {acc, depth, in_string?, false}}

          char == open ->
            {:cont, {acc, depth + 1, in_string?, false}}

          char == close ->
            if depth - 1 == 0 do
              {:halt, {acc, 0, in_string?, false}}
            else
              {:cont, {acc, depth - 1, in_string?, false}}
            end

          true ->
            {:cont, {acc, depth, in_string?, false}}
        end
      end)

    if depth == 0 and acc != [] do
      acc |> Enum.reverse() |> Enum.join()
    end
  end

  @doc """
  Pulls a list of items out of whatever shape the model actually returned.

  Asked for `{"findings": [...]}`, a small model will variously return the
  wrapper, a bare array, or a single bare object. All three mean the same thing,
  and rejecting two of them would throw away good work over punctuation.

      iex> JidoSwarm.Reasoning.items(%{"findings" => [%{"a" => 1}]}, "findings")
      [%{"a" => 1}]

      iex> JidoSwarm.Reasoning.items([%{"a" => 1}], "findings")
      [%{"a" => 1}]

      iex> JidoSwarm.Reasoning.items(%{"a" => 1}, "findings")
      [%{"a" => 1}]
  """
  @spec items(term(), String.t()) :: [map()]
  def items(value, key) when is_map(value) do
    case Map.get(value, key) do
      list when is_list(list) -> Enum.filter(list, &is_map/1)
      %{} = single -> [single]
      _ -> if map_size(value) > 0, do: [value], else: []
    end
  end

  def items(value, _key) when is_list(value), do: Enum.filter(value, &is_map/1)
  def items(_value, _key), do: []

  @doc """
  The system prompt every worker shares.

  Kept identical across workers on purpose: it is the stable prefix of every
  request, which is what makes prompt caching possible when the provider is
  Claude.
  """
  @spec system_prompt() :: String.t()
  def system_prompt do
    """
    You are one agent in a swarm of Elixir engineers working on three related open-source projects:

    - jido — an autonomous agent framework for Elixir (agents, actions, signals, plugins, runtime).
    - glider — an embeddable property-graph database written in Rust with zero dependencies.
    - glider_ex — Elixir bindings for glider, linked into the BEAM as a Rustler NIF.

    The swarm shares one knowledge graph. What you record is what every other agent will read,
    so be specific and concrete: name modules, files and functions rather than describing them.

    Rules:
    - Answer with the exact JSON shape you are asked for, and nothing else. No prose, no fences.
    - Prefer small, reviewable changes over ambitious ones.
    - Never invent a file path, module or function you have not been shown.
    - If you do not have enough information, say so in the JSON rather than guessing.
    """
  end

  @doc "Builds the standard message list: shared system prompt plus one user turn."
  @spec prompt(String.t()) :: [LLM.message()]
  def prompt(user) do
    [
      %{role: :system, content: system_prompt()},
      %{role: :user, content: user}
    ]
  end

  @doc """
  Truncates text to a token-ish budget, measured in characters.

  Crude on purpose — the providers disagree about tokenization and the only
  thing that matters here is not blowing the context window of whichever model
  is configured.
  """
  @spec clamp(String.t(), pos_integer()) :: String.t()
  def clamp(text, max_chars) when is_binary(text) do
    if String.length(text) > max_chars do
      String.slice(text, 0, max_chars) <> "\n… (truncated)"
    else
      text
    end
  end

  def clamp(nil, _), do: ""
end
