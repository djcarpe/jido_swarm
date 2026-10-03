defmodule JidoSwarm.LLM.RagenticTest do
  use ExUnit.Case, async: false

  alias JidoSwarm.LLM.Ragentic

  setup do
    previous = Application.get_env(:jido_swarm, JidoSwarm.LLM, [])

    Application.put_env(
      :jido_swarm,
      JidoSwarm.LLM,
      Keyword.put(previous, :ragentic,
        base_url: "http://ragentic.test/",
        token: "ragentic_t0k3n",
        model: "lap/qwen3",
        req_options: [plug: {Req.Test, Ragentic}]
      )
    )

    on_exit(fn -> Application.put_env(:jido_swarm, JidoSwarm.LLM, previous) end)
    :ok
  end

  test "lists the gateway's models and is ready when it answers" do
    Req.Test.stub(Ragentic, fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer ragentic_t0k3n"]
      assert conn.request_path == "/v1/models"

      Req.Test.json(conn, %{
        "object" => "list",
        "data" => [%{"id" => "lap/qwen3"}, %{"id" => "deepseek/deepseek-chat"}]
      })
    end)

    assert {:ok, ["lap/qwen3", "deepseek/deepseek-chat"]} = Ragentic.models()
    assert Ragentic.ready?()
    assert Ragentic.model() == "lap/qwen3"
  end

  test "is not ready, and says why, when the gateway refuses or is unconfigured" do
    Req.Test.stub(Ragentic, fn conn ->
      conn |> Plug.Conn.put_status(401) |> Req.Test.json(%{"error" => "an API key is required"})
    end)

    refute Ragentic.ready?()
    assert Ragentic.readiness_hint() =~ "token"

    config = Application.get_env(:jido_swarm, JidoSwarm.LLM)

    Application.put_env(
      :jido_swarm,
      JidoSwarm.LLM,
      Keyword.put(config, :ragentic, Keyword.put(config[:ragentic], :model, nil))
    )

    refute Ragentic.ready?()
    assert Ragentic.readiness_hint() =~ "RAGENTIC_MODEL"
  end

  test "a tool-calling round trip in the OpenAI shape, with the job's model" do
    test = self()

    Req.Test.stub(Ragentic, fn conn ->
      send(test, {:sent, conn.body_params})
      assert conn.request_path == "/v1/chat/completions"

      message =
        if Enum.any?(conn.body_params["messages"], &(&1["role"] == "tool")) do
          %{"role" => "assistant", "content" => "mix.exs defines :jido_swarm."}
        else
          %{
            "role" => "assistant",
            "content" => "",
            "tool_calls" => [
              %{
                "id" => "call_1",
                "type" => "function",
                "function" => %{"name" => "read_file", "arguments" => ~s({"path":"mix.exs"})}
              }
            ]
          }
        end

      finish = if message["tool_calls"], do: "tool_calls", else: "stop"

      Req.Test.json(conn, %{
        "model" => conn.body_params["model"],
        "choices" => [%{"index" => 0, "message" => message, "finish_reason" => finish}],
        "usage" => %{"prompt_tokens" => 7, "completion_tokens" => 3}
      })
    end)

    tools = [
      %{
        name: "read_file",
        description: "Read a file",
        schema: %{"type" => "object", "properties" => %{"path" => %{"type" => "string"}}}
      }
    ]

    messages = [
      %{role: :system, content: "Be brief."},
      %{role: :user, content: "What does mix.exs define?"}
    ]

    assert {:ok, first} =
             Ragentic.chat(messages,
               tools: tools,
               model: "deepseek/deepseek-chat",
               max_tokens: 500
             )

    assert first.stop == :tool_use

    assert [%{id: "call_1", name: "read_file", arguments: %{"path" => "mix.exs"}}] =
             first.tool_calls

    assert first.usage == %{input_tokens: 7, output_tokens: 3}
    assert first.model == "deepseek/deepseek-chat"

    assert_received {:sent, sent}

    assert sent["model"] == "deepseek/deepseek-chat" and sent["max_tokens"] == 500 and
             sent["stream"] == false

    assert [%{"type" => "function", "function" => %{"name" => "read_file"}}] = sent["tools"]

    next =
      messages ++
        [
          JidoSwarm.LLM.assistant_message(first),
          JidoSwarm.LLM.tool_message(hd(first.tool_calls), "defmodule JidoSwarm.MixProject")
        ]

    assert {:ok, second} = Ragentic.chat(next, tools: tools)
    assert second.text == "mix.exs defines :jido_swarm." and second.stop == :end_turn

    assert_received {:sent, replay}
    assert replay["model"] == "lap/qwen3"
    assert Enum.map(replay["messages"], & &1["role"]) == ["system", "user", "assistant", "tool"]

    assert get_in(Enum.at(replay["messages"], 2), [
             "tool_calls",
             Access.at(0),
             "function",
             "arguments"
           ]) == ~s({"path":"mix.exs"})

    assert Enum.at(replay["messages"], 3)["tool_call_id"] == "call_1"
  end

  test "an upstream error comes back as such, and nothing is retried" do
    counter = :counters.new(1, [])

    Req.Test.stub(Ragentic, fn conn ->
      :counters.add(counter, 1, 1)

      conn
      |> Plug.Conn.put_status(502)
      |> Req.Test.json(%{
        "error" => %{"message" => "lap is offline", "code" => "upstream_unreachable"}
      })
    end)

    assert {:error, {:http, 502, %{"error" => %{"code" => "upstream_unreachable"}}}} =
             Ragentic.chat([%{role: :user, content: "hi"}])

    assert :counters.get(counter, 1) == 1
  end
end
