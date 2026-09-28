defmodule JidoSwarm.ReasoningTest do
  use ExUnit.Case, async: true

  doctest JidoSwarm.Reasoning

  alias JidoSwarm.Reasoning

  describe "extract_json/2" do
    test "parses a bare JSON object" do
      assert {:ok, %{"a" => 1}} = Reasoning.extract_json(~s({"a": 1}), :object)
    end

    test "finds JSON wrapped in prose" do
      text = ~s(Sure! Here is the result:\n\n{"a": 1}\n\nLet me know if that helps.)
      assert {:ok, %{"a" => 1}} = Reasoning.extract_json(text, :object)
    end

    test "finds JSON inside a fenced block" do
      text = "Here you go:\n```json\n{\"a\": 1}\n```\n"
      assert {:ok, %{"a" => 1}} = Reasoning.extract_json(text, :object)
    end

    test "finds JSON inside an unlabelled fence" do
      text = "```\n{\"a\": 1}\n```"
      assert {:ok, %{"a" => 1}} = Reasoning.extract_json(text, :object)
    end

    test "a brace inside a string does not end the span early" do
      text = ~s(prefix {"note": "a } inside a string", "b": 2} suffix)
      assert {:ok, decoded} = Reasoning.extract_json(text, :object)
      assert decoded["b"] == 2
      assert decoded["note"] =~ "}"
    end

    test "an escaped quote inside a string does not end the string early" do
      text = ~s(x {"note": "she said \\"hi\\"", "b": 2} y)
      assert {:ok, decoded} = Reasoning.extract_json(text, :object)
      assert decoded["b"] == 2
    end

    test "takes the first object when asked for one and given an array" do
      assert {:ok, %{"a" => 1}} = Reasoning.extract_json(~s([{"a": 1}, {"a": 2}]), :object)
    end

    test "wraps a lone object when asked for a list" do
      assert {:ok, [%{"a" => 1}]} = Reasoning.extract_json(~s({"a": 1}), :list)
    end

    test "is :error when there is no JSON at all" do
      assert :error = Reasoning.extract_json("I could not do that.", :object)
    end

    test "is :error for a JSON scalar, which is never a useful answer here" do
      assert :error = Reasoning.extract_json("42", :object)
    end
  end

  describe "items/2" do
    test "unwraps the requested key" do
      assert [%{"a" => 1}] = Reasoning.items(%{"findings" => [%{"a" => 1}]}, "findings")
    end

    test "accepts a bare list, which small models return instead of the wrapper" do
      assert [%{"a" => 1}] = Reasoning.items([%{"a" => 1}], "findings")
    end

    test "accepts a single bare object" do
      assert [%{"a" => 1}] = Reasoning.items(%{"a" => 1}, "findings")
    end

    test "accepts a single object under the key" do
      assert [%{"a" => 1}] = Reasoning.items(%{"findings" => %{"a" => 1}}, "findings")
    end

    test "drops non-map entries rather than passing them on" do
      assert [%{"a" => 1}] =
               Reasoning.items(%{"findings" => [%{"a" => 1}, "junk", 3]}, "findings")
    end

    test "is empty for an empty map or a non-collection" do
      assert [] = Reasoning.items(%{}, "findings")
      assert [] = Reasoning.items("nope", "findings")
      assert [] = Reasoning.items(nil, "findings")
    end
  end

  describe "clamp/2" do
    test "leaves short text alone" do
      assert Reasoning.clamp("short", 100) == "short"
    end

    test "truncates and says so" do
      clamped = Reasoning.clamp(String.duplicate("x", 200), 50)
      assert String.starts_with?(clamped, String.duplicate("x", 50))
      assert clamped =~ "truncated"
    end

    test "treats nil as empty" do
      assert Reasoning.clamp(nil, 10) == ""
    end
  end
end
