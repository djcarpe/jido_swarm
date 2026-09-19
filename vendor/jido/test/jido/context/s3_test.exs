defmodule Jido.Context.S3Test do
  # Not async: the HTTP client is resolved from application config.
  use ExUnit.Case, async: false

  alias Jido.Context.S3
  alias Jido.Context.Store
  alias JidoTest.FakeS3

  setup do
    previous = Application.get_env(:jido, Jido.Context, [])

    Application.put_env(
      :jido,
      Jido.Context,
      Keyword.put(previous, :s3_http_client, FakeS3)
    )

    start_supervised!(FakeS3)

    on_exit(fn -> Application.put_env(:jido, Jido.Context, previous) end)

    store =
      Store.normalize(
        {:s3,
         bucket: "graphs",
         prefix: "mesh",
         endpoint: "http://fake-s3.test:9000",
         access_key_id: "AKID",
         secret_access_key: "SECRET"}
      )

    {:ok, store: store}
  end

  describe "config/1" do
    test "defaults to AWS for the region and virtual-hosted addressing" do
      config = S3.config(bucket: "b", region: "eu-west-1")

      assert config.endpoint == "https://s3.eu-west-1.amazonaws.com"
      refute config.path_style
    end

    test "a custom endpoint implies path-style addressing" do
      config = S3.config(bucket: "b", endpoint: "http://minio:9000")

      assert config.endpoint == "http://minio:9000"
      assert config.path_style
    end

    test "path_style can be forced either way" do
      assert S3.config(bucket: "b", path_style: true).path_style
      refute S3.config(bucket: "b", endpoint: "http://minio:9000", path_style: false).path_style
    end

    test "a trailing slash on the endpoint is dropped" do
      assert S3.config(bucket: "b", endpoint: "http://minio:9000/").endpoint ==
               "http://minio:9000"
    end

    test "an empty prefix is treated as none" do
      assert S3.config(bucket: "b", prefix: "").prefix == nil
      assert S3.config(bucket: "b", prefix: "/a/b/").prefix == "a/b"
    end

    test "requires a bucket" do
      assert_raise KeyError, fn -> S3.config(region: "us-east-1") end
    end
  end

  describe "credentials/1" do
    test "prefers explicit options" do
      creds = S3.credentials(access_key_id: "A", secret_access_key: "B")
      assert creds.access_key_id == "A"
      assert creds.secret_access_key == "B"
    end

    test "falls back to the standard environment variables" do
      System.put_env("AWS_ACCESS_KEY_ID", "FROM_ENV")
      on_exit(fn -> System.delete_env("AWS_ACCESS_KEY_ID") end)

      assert S3.credentials([]).access_key_id == "FROM_ENV"
    end
  end

  describe "parse_list_result/1" do
    test "extracts keys and unescapes XML entities" do
      xml = """
      <ListBucketResult>
        <IsTruncated>false</IsTruncated>
        <Contents><Key>a/b.json</Key></Contents>
        <Contents><Key>a&amp;b</Key></Contents>
        <Contents><Key>x&lt;y</Key></Contents>
      </ListBucketResult>
      """

      assert {["a/b.json", "a&b", "x<y"], nil} = S3.parse_list_result(xml)
    end

    test "returns the continuation token only when the result is truncated" do
      truncated = """
      <ListBucketResult>
        <IsTruncated>true</IsTruncated>
        <NextContinuationToken>tok</NextContinuationToken>
        <Contents><Key>a</Key></Contents>
      </ListBucketResult>
      """

      assert {["a"], "tok"} = S3.parse_list_result(truncated)

      complete = String.replace(truncated, "true", "false")
      assert {["a"], nil} = S3.parse_list_result(complete)
    end

    test "handles an empty listing" do
      assert {[], nil} =
               S3.parse_list_result(
                 "<ListBucketResult><IsTruncated>false</IsTruncated></ListBucketResult>"
               )
    end

    test "does not double-unescape - &amp;lt; stays &lt;" do
      xml =
        "<ListBucketResult><IsTruncated>false</IsTruncated><Contents><Key>a&amp;lt;b</Key></Contents></ListBucketResult>"

      assert {["a&lt;b"], nil} = S3.parse_list_result(xml)
    end
  end

  describe "store operations" do
    test "put, get and delete round-trip", %{store: store} do
      assert :ok = Store.put(store, "snapshots/g1.jsonl", "line one")
      assert {:ok, "line one"} = Store.get(store, "snapshots/g1.jsonl")
      assert :ok = Store.delete(store, "snapshots/g1.jsonl")
      assert :not_found = Store.get(store, "snapshots/g1.jsonl")
    end

    test "a missing key is :not_found, not an error", %{store: store} do
      assert :not_found = Store.get(store, "nope")
    end

    test "objects land under the configured prefix and bucket", %{store: store} do
      :ok = Store.put(store, "topics/t/o/1.json", "x")

      assert Map.has_key?(FakeS3.objects(), "/graphs/mesh/topics/t/o/1.json")
    end

    test "listing strips the prefix back off, so callers see the keys they wrote", %{store: store} do
      :ok = Store.put(store, "topics/t/o/1.json", "x")
      :ok = Store.put(store, "topics/t/o/2.json", "y")

      assert {:ok, ["topics/t/o/1.json", "topics/t/o/2.json"]} = Store.list(store, "topics/t/")
    end

    test "listing follows continuation tokens past the page size", %{store: store} do
      for i <- 1..7 do
        :ok = Store.put(store, "topics/t/o/#{i}.json", "x")
      end

      assert {:ok, keys} = Store.list(store, "topics/t/o/")
      assert length(keys) == 7
      assert keys == Enum.sort(keys)
    end

    test ":after returns only later keys - this is what makes the log tailable", %{store: store} do
      for i <- 1..5, do: :ok = Store.put(store, "topics/t/o/#{i}.json", "x")

      assert {:ok, keys} = Store.list(store, "topics/t/o/", after: "topics/t/o/3.json")
      assert keys == ["topics/t/o/4.json", "topics/t/o/5.json"]
    end

    test ":limit caps the result", %{store: store} do
      for i <- 1..5, do: :ok = Store.put(store, "topics/t/o/#{i}.json", "x")

      assert {:ok, keys} = Store.list(store, "topics/t/o/", limit: 3)
      assert length(keys) == 3
    end

    test "a prefix that matches nothing lists empty", %{store: store} do
      assert {:ok, []} = Store.list(store, "nothing/")
    end

    test "content type is derived from the key's extension", %{store: store} do
      :ok = Store.put(store, "a.json", "{}")

      assert Enum.any?(FakeS3.requests(), fn {method, path, _} ->
               method == :put and path =~ "a.json"
             end)
    end

    test "{:system, VAR} credentials are read from the environment" do
      System.put_env("JIDO_TEST_S3_KEY", "FROM_SYSTEM")
      on_exit(fn -> System.delete_env("JIDO_TEST_S3_KEY") end)

      store =
        Store.normalize(
          {:s3,
           bucket: "graphs",
           endpoint: "http://fake-s3.test:9000",
           access_key_id: {:system, "JIDO_TEST_S3_KEY"},
           secret_access_key: "SECRET"}
        )

      assert :ok = Store.put(store, "k", "v")
      assert {:ok, "v"} = Store.get(store, "k")
    end
  end

  describe "request shape" do
    test "path-style requests address the bucket in the path", %{store: store} do
      :ok = Store.put(store, "k", "v")

      assert Enum.any?(FakeS3.requests(), fn {method, path, _} ->
               method == :put and path == "/graphs/mesh/k"
             end)
    end

    test "a listing is a GET on the bucket with list-type=2", %{store: store} do
      {:ok, _} = Store.list(store, "topics/")

      assert Enum.any?(FakeS3.requests(), fn {method, path, query} ->
               method == :get and path == "/graphs" and query["list-type"] == "2"
             end)
    end
  end
end
