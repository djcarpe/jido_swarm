defmodule Jido.Context.StoreTest do
  use ExUnit.Case, async: true

  doctest Jido.Context.Store

  alias Jido.Context.Store

  describe "normalize/1" do
    test "expands the shorthands" do
      assert Store.normalize(:memory) == {Store.Memory, []}
      assert Store.normalize({:memory, [a: 1]}) == {Store.Memory, [a: 1]}
      assert Store.normalize({:disk, path: "/tmp/x"}) == {Store.Disk, [path: "/tmp/x"]}
      assert Store.normalize({:s3, bucket: "b"}) == {Store.S3, [bucket: "b"]}
    end

    test "passes a module through" do
      assert Store.normalize(Store.Memory) == {Store.Memory, []}
      assert Store.normalize({Store.Memory, [a: 1]}) == {Store.Memory, [a: 1]}
    end
  end
end

defmodule Jido.Context.Store.MemoryTest do
  # Not async: the ETS table is process-independent and shared.
  use ExUnit.Case, async: false

  use JidoTest.ContextStoreConformance,
    adapter: Jido.Context.Store.Memory,
    setup: quote(do: [])

  alias Jido.Context.Store.Memory

  setup do
    Memory.reset()
    :ok
  end

  test "the table survives a process that touched it going away" do
    task = Task.async(fn -> Memory.put("k.json", "v", []) end)
    Task.await(task)

    assert {:ok, "v"} = Memory.get("k.json", [])
  end

  test "reset clears everything" do
    :ok = Memory.put("k.json", "v", [])
    :ok = Memory.reset()

    assert :not_found = Memory.get("k.json", [])
  end
end

defmodule Jido.Context.Store.DiskTest do
  use ExUnit.Case, async: true

  use JidoTest.ContextStoreConformance,
    adapter: Jido.Context.Store.Disk,
    setup: quote(do: [path: Jido.Context.Store.DiskTest.unique_dir()])

  alias Jido.Context.Store.Disk

  @doc false
  def unique_dir do
    dir =
      Path.join(
        System.tmp_dir!(),
        "jido_ctx_store_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  setup do
    {:ok, path: unique_dir()}
  end

  test "keys become real paths under the base directory", %{path: path} do
    :ok = Disk.put("topics/t/o/1.json", "hello", path: path)

    assert File.read!(Path.join(path, "topics/t/o/1.json")) == "hello"
  end

  describe "key validation" do
    test "rejects a traversal", %{path: path} do
      assert {:error, {:invalid_key, _}} = Disk.put("../escape.json", "x", path: path)
      assert {:error, {:invalid_key, _}} = Disk.put("a/../../escape.json", "x", path: path)
      assert {:error, {:invalid_key, _}} = Disk.get("../../etc/passwd", path: path)
    end

    test "rejects a lone dot segment", %{path: path} do
      assert {:error, {:invalid_key, _}} = Disk.put("a/./b.json", "x", path: path)
    end

    test "rejects an absolute key", %{path: path} do
      assert {:error, {:invalid_key, _}} = Disk.put("/etc/passwd", "x", path: path)
    end

    test "rejects characters that are not path-safe", %{path: path} do
      assert {:error, {:invalid_key, _}} = Disk.put("a b/c.json", "x", path: path)
      assert {:error, {:invalid_key, _}} = Disk.put("a\0b", "x", path: path)
    end

    test "a traversal attempt writes nothing outside the base", %{path: path} do
      outside =
        Path.join(System.tmp_dir!(), "jido_ctx_escaped_#{System.unique_integer([:positive])}")

      on_exit(fn -> File.rm_rf(outside) end)

      relative = Path.relative_to(outside, path)
      {:error, {:invalid_key, _}} = Disk.put(relative, "pwned", path: path)

      refute File.exists?(outside)
    end
  end

  test "a partially written file is not listed", %{path: path} do
    File.mkdir_p!(Path.join(path, "topics"))
    File.write!(Path.join(path, "topics/x.json.tmp-123"), "half")
    :ok = Disk.put("topics/y.json", "whole", path: path)

    assert {:ok, ["topics/y.json"]} = Disk.list("topics/", path: path)
  end

  test "writes are atomic - no temp file is left behind on success", %{path: path} do
    :ok = Disk.put("k.json", "v", path: path)

    assert File.ls!(path) == ["k.json"]
  end
end
