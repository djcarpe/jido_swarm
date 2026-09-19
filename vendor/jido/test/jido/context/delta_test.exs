defmodule Jido.Context.DeltaTest do
  use ExUnit.Case, async: true

  doctest Jido.Context.Delta

  alias Jido.Context.Delta

  describe "new/5" do
    test "stamps a delta and validates its operations" do
      delta =
        Delta.new("knowledge.papers", "scout", 3, [
          {:put_node, "paper:1", ["Paper"], %{"title" => "A"}}
        ])

      assert delta.topic == "knowledge.papers"
      assert delta.origin == "scout"
      assert delta.seq == 3
      assert is_integer(delta.ts)
      assert String.starts_with?(delta.id, "dlt_")
    end

    test "rejects a topic that is not dot-separated segments" do
      for bad <- ["has space", "a/b", "trailing.", ".leading", ""] do
        assert_raise ArgumentError, ~r/invalid topic/, fn -> Delta.new(bad, "scout", 1, []) end
      end
    end

    test "rejects an origin that would not be a safe path segment" do
      for bad <- ["a/b", "..", "with space", ""] do
        assert_raise ArgumentError, ~r/invalid origin/, fn -> Delta.new("t", bad, 1, []) end
      end
    end

    test "rejects a label or relationship type that is not an identifier" do
      assert_raise ArgumentError, fn ->
        Delta.new("t", "o", 1, [{:put_node, "k", ["Not Valid"], %{}}])
      end

      assert_raise ArgumentError, fn ->
        Delta.new("t", "o", 1, [{:put_edge, "a", "BAD TYPE", "b", %{}}])
      end
    end

    test "rejects a reserved leading-underscore property" do
      assert_raise ArgumentError, ~r/reserved/, fn ->
        Delta.new("t", "o", 1, [{:put_node, "k", [], %{"_seq" => 99}}])
      end
    end

    test "allows any binary as an entity key - keys are values, not identifiers" do
      delta = Delta.new("t", "o", 1, [{:put_node, ~S|weird "key" with spaces|, [], %{}}])
      assert [{:put_node, ~S|weird "key" with spaces|, [], %{}}] = delta.ops
    end
  end

  describe "compare_stamp/2" do
    test "orders by sequence first" do
      assert Delta.compare_stamp({2, "a"}, {1, "z"}) == :gt
      assert Delta.compare_stamp({1, "z"}, {2, "a"}) == :lt
    end

    test "breaks ties on origin" do
      assert Delta.compare_stamp({1, "b"}, {1, "a"}) == :gt
      assert Delta.compare_stamp({1, "a"}, {1, "b"}) == :lt
    end

    test "is equal only when both parts match" do
      assert Delta.compare_stamp({1, "a"}, {1, "a"}) == :eq
    end

    test "is a total order - every pair is comparable and antisymmetric" do
      stamps = for seq <- 1..4, origin <- ["a", "b", "c"], do: {seq, origin}

      for x <- stamps, y <- stamps do
        case Delta.compare_stamp(x, y) do
          :eq -> assert Delta.compare_stamp(y, x) == :eq
          :gt -> assert Delta.compare_stamp(y, x) == :lt
          :lt -> assert Delta.compare_stamp(y, x) == :gt
        end
      end
    end
  end

  describe "topic_match?/2" do
    test "matches an exact topic" do
      assert Delta.topic_match?("knowledge.papers", "knowledge.papers")
      refute Delta.topic_match?("knowledge.papers", "knowledge.books")
    end

    test "* matches exactly one segment" do
      assert Delta.topic_match?("knowledge.papers", "knowledge.*")
      refute Delta.topic_match?("knowledge.papers.nlp", "knowledge.*")
      refute Delta.topic_match?("knowledge", "knowledge.*")
    end

    test "** matches the remainder" do
      assert Delta.topic_match?("knowledge.papers", "knowledge.**")
      assert Delta.topic_match?("knowledge.papers.nlp", "knowledge.**")
      assert Delta.topic_match?("anything.at.all", "**")
    end

    test "a pattern does not match a shorter topic" do
      refute Delta.topic_match?("knowledge", "knowledge.papers")
    end
  end

  describe "encode/1 and decode/1" do
    test "round-trips every operation shape" do
      delta =
        Delta.new("knowledge.papers", "scout", 7, [
          {:put_node, "paper:1", ["Paper", "Cited"], %{"title" => "A", "year" => 2017}},
          {:drop_node, "paper:2"},
          {:put_edge, "paper:1", "CITES", "paper:3", %{"section" => "intro"}},
          {:drop_edge, "paper:1", "CITES", "paper:4"}
        ])

      assert {:ok, decoded} = delta |> Delta.encode() |> Delta.decode()
      assert decoded == delta
    end

    test "round-trips values that need escaping" do
      delta = Delta.new("t", "o", 1, [{:put_node, ~S|a"b|, [], %{"v" => "line\nbreak"}}])
      assert {:ok, decoded} = delta |> Delta.encode() |> Delta.decode()
      assert decoded == delta
    end

    test "returns an error for malformed JSON rather than raising" do
      assert {:error, _} = Delta.decode("not json")
    end

    test "returns an error for JSON that is not a delta" do
      assert {:error, :malformed_delta} = Delta.decode(~S|{"hello": "world"}|)
    end

    test "returns an error for an unknown operation tag" do
      json = ~S|{"id":"dlt_1","topic":"t","origin":"o","seq":1,"ts":1,"ops":[["nuke","x"]]}|
      assert {:error, message} = Delta.decode(json)
      assert message =~ "unknown delta op"
    end

    test "rejects a hostile label arriving from a peer" do
      json =
        ~S|{"id":"dlt_1","topic":"t","origin":"o","seq":1,"ts":1,| <>
          ~S|"ops":[["put_node","k",["X {a:1}) DETACH DELETE n //"],{}]]}|

      assert {:error, message} = Delta.decode(json)
      assert message =~ "invalid Cypher identifier"
    end
  end
end
