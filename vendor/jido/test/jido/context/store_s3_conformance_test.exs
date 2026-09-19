defmodule Jido.Context.Store.S3ConformanceTest do
  @moduledoc """
  The S3 adapter against the same contract as Memory and Disk.

  `Jido.Context.Mesh.Log` is written against the store contract alone, so the
  ordering and `:after` semantics it tails a topic log with have to hold here
  exactly as they do on a local disk — otherwise the mesh works in tests and
  loses deltas in production.
  """

  # Not async: the HTTP client is resolved from application config.
  use ExUnit.Case, async: false

  use JidoTest.ContextStoreConformance,
    adapter: Jido.Context.Store.S3,
    setup: quote(do: Jido.Context.Store.S3ConformanceTest.opts())

  alias JidoTest.FakeS3

  setup do
    previous = Application.get_env(:jido, Jido.Context, [])
    Application.put_env(:jido, Jido.Context, Keyword.put(previous, :s3_http_client, FakeS3))
    start_supervised!(FakeS3)
    on_exit(fn -> Application.put_env(:jido, Jido.Context, previous) end)
    :ok
  end

  @doc false
  def opts do
    [
      bucket: "conformance",
      prefix: "ctx",
      endpoint: "http://fake-s3.test:9000",
      access_key_id: "AKID",
      secret_access_key: "SECRET"
    ]
  end
end
