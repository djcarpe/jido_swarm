defmodule JidoTest.ContextStoreConformance do
  @moduledoc """
  Reusable ExUnit cases for the `Jido.Context.Store` contract.

  Every adapter must behave identically here, because `Jido.Context.Mesh.Log`
  is written against this contract alone — the ordering guarantees it relies on
  to tail a topic log are contract, not an S3 implementation detail.

  The caller supplies the adapter and an option expression, evaluated afresh for
  each test so adapters can create isolated directories or tables.

      use JidoTest.ContextStoreConformance,
        adapter: Jido.Context.Store.Disk,
        setup: quote(do: [path: unique_dir()])
  """

  defmacro __using__(options) do
    adapter = Keyword.fetch!(options, :adapter)

    setup =
      case Keyword.get(options, :setup, quote(do: [])) do
        {:quote, _, [[do: expression]]} -> expression
        expression -> expression
      end

    quote do
      alias unquote(adapter), as: ContextStoreAdapter

      describe "context store conformance" do
        test "a missing key is :not_found, not an error" do
          opts = unquote(setup)
          assert :not_found = ContextStoreAdapter.get("absent/key.json", opts)
        end

        test "stores and retrieves a value" do
          opts = unquote(setup)

          assert :ok = ContextStoreAdapter.put("a/b.json", "hello", opts)
          assert {:ok, "hello"} = ContextStoreAdapter.get("a/b.json", opts)
        end

        test "put overwrites" do
          opts = unquote(setup)

          assert :ok = ContextStoreAdapter.put("k.json", "first", opts)
          assert :ok = ContextStoreAdapter.put("k.json", "second", opts)
          assert {:ok, "second"} = ContextStoreAdapter.get("k.json", opts)
        end

        test "round-trips bytes that are not valid UTF-8" do
          opts = unquote(setup)
          blob = <<0, 1, 2, 255, 254>>

          assert :ok = ContextStoreAdapter.put("blob.json", blob, opts)
          assert {:ok, ^blob} = ContextStoreAdapter.get("blob.json", opts)
        end

        test "round-trips an empty value" do
          opts = unquote(setup)

          assert :ok = ContextStoreAdapter.put("empty.json", "", opts)
          assert {:ok, ""} = ContextStoreAdapter.get("empty.json", opts)
        end

        test "delete removes a key" do
          opts = unquote(setup)

          :ok = ContextStoreAdapter.put("k.json", "v", opts)
          assert :ok = ContextStoreAdapter.delete("k.json", opts)
          assert :not_found = ContextStoreAdapter.get("k.json", opts)
        end

        test "delete of a missing key is :ok" do
          opts = unquote(setup)
          assert :ok = ContextStoreAdapter.delete("never/existed.json", opts)
        end

        test "list returns keys under a prefix, in lexicographic order" do
          opts = unquote(setup)

          for key <- ["t/o/3.json", "t/o/1.json", "t/o/2.json", "other/x.json"] do
            :ok = ContextStoreAdapter.put(key, "v", opts)
          end

          assert {:ok, keys} = ContextStoreAdapter.list("t/o/", opts)
          assert keys == ["t/o/1.json", "t/o/2.json", "t/o/3.json"]
        end

        test "list excludes keys outside the prefix" do
          opts = unquote(setup)

          :ok = ContextStoreAdapter.put("topics/a/x.json", "v", opts)
          :ok = ContextStoreAdapter.put("members/a/x", "v", opts)

          assert {:ok, ["topics/a/x.json"]} = ContextStoreAdapter.list("topics/", opts)
        end

        test "list with :after returns only strictly greater keys" do
          opts = unquote(setup)

          for i <- 1..4, do: :ok = ContextStoreAdapter.put("t/o/#{i}.json", "v", opts)

          assert {:ok, keys} =
                   ContextStoreAdapter.list("t/o/", Keyword.put(opts, :after, "t/o/2.json"))

          assert keys == ["t/o/3.json", "t/o/4.json"]
        end

        test "list with :after past the end is empty" do
          opts = unquote(setup)

          :ok = ContextStoreAdapter.put("t/o/1.json", "v", opts)

          assert {:ok, []} =
                   ContextStoreAdapter.list("t/o/", Keyword.put(opts, :after, "t/o/9.json"))
        end

        test "list with :limit caps the result, keeping the earliest keys" do
          opts = unquote(setup)

          for i <- 1..5, do: :ok = ContextStoreAdapter.put("t/o/#{i}.json", "v", opts)

          assert {:ok, keys} = ContextStoreAdapter.list("t/o/", Keyword.put(opts, :limit, 2))
          assert keys == ["t/o/1.json", "t/o/2.json"]
        end

        test "list of an empty prefix is an empty list, not an error" do
          opts = unquote(setup)
          assert {:ok, []} = ContextStoreAdapter.list("nothing/here/", opts)
        end

        test "zero-padded sequence keys sort numerically, which the topic log depends on" do
          opts = unquote(setup)

          for seq <- [1, 2, 10, 100] do
            key = "t/o/" <> String.pad_leading(Integer.to_string(seq), 20, "0") <> ".json"
            :ok = ContextStoreAdapter.put(key, Integer.to_string(seq), opts)
          end

          assert {:ok, keys} = ContextStoreAdapter.list("t/o/", opts)

          values =
            Enum.map(keys, fn key ->
              {:ok, v} = ContextStoreAdapter.get(key, opts)
              String.to_integer(v)
            end)

          assert values == [1, 2, 10, 100]
        end
      end
    end
  end
end
