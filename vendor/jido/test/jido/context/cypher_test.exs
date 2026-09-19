defmodule Jido.Context.CypherTest do
  use ExUnit.Case, async: true

  doctest Jido.Context.Cypher

  alias Jido.Context.Cypher

  describe "encode_value/1" do
    test "encodes the Glider scalar types" do
      assert Cypher.encode_value(nil) == "null"
      assert Cypher.encode_value(true) == "true"
      assert Cypher.encode_value(false) == "false"
      assert Cypher.encode_value(42) == "42"
      assert Cypher.encode_value(-7) == "-7"
      assert Cypher.encode_value("hi") == ~S|"hi"|
    end

    test "keeps a decimal point on integral floats so they do not read back as ints" do
      assert Cypher.encode_value(1.0) == "1.0"
      assert Cypher.encode_value(1.5) == "1.5"
    end

    test "escapes quotes and backslashes" do
      assert Cypher.encode_value(~S|say "hi"|) == ~S|"say \"hi\""|
      assert Cypher.encode_value("back\\slash") == ~S|"back\\slash"|
    end

    test "escapes control characters rather than emitting them raw" do
      assert Cypher.encode_value("a\nb") == ~S|"a\nb"|
      assert Cypher.encode_value("a\tb") == ~S|"a\tb"|
      assert Cypher.encode_value("a\rb") == ~S|"a\rb"|
      # A raw control byte becomes a \uXXXX escape, not a literal byte.
      assert Cypher.encode_value(<<1>>) == "\"" <> "\\u0001" <> "\""
    end

    test "passes multi-byte UTF-8 through unchanged" do
      assert Cypher.encode_value("café ✓") == ~S|"café ✓"|
    end

    test "encodes lists element-wise" do
      assert Cypher.encode_value([1, "a", nil, true]) == ~S|[1, "a", null, true]|
      assert Cypher.encode_value([]) == "[]"
    end

    test "renders a term with no literal form as its inspect text" do
      assert Cypher.encode_value({:a, :b}) == ~S|"{:a, :b}"|
    end

    test "a value that tries to break out of the string stays inside it" do
      # The classic injection: close the quote, close the pattern, append a
      # statement. All of it must survive as text.
      hostile = ~S|"}) DETACH DELETE n CREATE (x:Pwned {a:"|
      encoded = Cypher.encode_value(hostile)

      assert String.starts_with?(encoded, ~S|"\"}|)
      refute encoded =~ ~S|{a:"|
      # Exactly two unescaped quotes: the delimiters.
      assert encoded
             |> String.replace(~S|\"|, "")
             |> String.graphemes()
             |> Enum.count(&(&1 == "\"")) ==
               2
    end
  end

  describe "identifier!/1" do
    test "accepts identifier-shaped names" do
      assert Cypher.identifier!("Person") == "Person"
      assert Cypher.identifier!("_seq") == "_seq"
      assert Cypher.identifier!("a1_B2") == "a1_B2"
      assert Cypher.identifier!(:atom_name) == "atom_name"
    end

    test "rejects anything that could alter the query" do
      for bad <- ["Person {x:1}) DELETE n //", "has space", "1leading", "", "a-b", "a.b", ~S|a"b|] do
        assert_raise ArgumentError, fn -> Cypher.identifier!(bad) end
      end
    end

    test "identifier/1 returns a tagged tuple instead of raising" do
      assert {:ok, "Person"} = Cypher.identifier("Person")
      assert {:error, message} = Cypher.identifier("not valid")
      assert message =~ "invalid Cypher identifier"
    end
  end

  describe "props/1" do
    test "renders a sorted map literal" do
      assert Cypher.props(%{"name" => "Ada", "age" => 36}) == ~S|{age: 36, name: "Ada"}|
    end

    test "is empty for an empty map, so it concatenates unconditionally" do
      assert Cypher.props(%{}) == ""
    end

    test "rejects a hostile property key" do
      assert_raise ArgumentError, fn -> Cypher.props(%{"a}) DELETE n //" => 1}) end
    end
  end

  describe "set_props/2" do
    test "renders sorted assignments bound to a variable" do
      assert Cypher.set_props("n", %{"b" => 2, "a" => 1}) == "n.a = 1, n.b = 2"
    end

    test "is nil for an empty map so the clause can be skipped" do
      assert Cypher.set_props("n", %{}) == nil
    end
  end

  describe "labels/1" do
    test "renders a label suffix" do
      assert Cypher.labels(["Person", "Author"]) == ":Person:Author"
      assert Cypher.labels([]) == ""
    end
  end
end
