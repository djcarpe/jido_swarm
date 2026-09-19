defmodule Jido.Context.Store.S3 do
  @moduledoc """
  A `Jido.Context.Store` backed by S3-compatible object storage.

  This is the store that makes a mesh span more than one node. Snapshots and
  topic-log deltas become objects; every agent that can reach the bucket can
  reach the mesh, with no direct connectivity between agents and no coordinator.

  ## Options

  Everything `Jido.Context.S3.config/1` accepts, plus credentials:

      store: {:s3,
        bucket: "agent-graphs",
        prefix: "mesh/prod",
        region: "us-west-2",
        endpoint: "http://minio.internal:9000",   # optional
        access_key_id: {:system, "MINIO_KEY"},    # or a literal, or omit for AWS_ACCESS_KEY_ID
        secret_access_key: {:system, "MINIO_SECRET"}
      }

  ## Consistency

  S3 has been read-after-write consistent for new objects since 2020, and
  list-after-write is consistent too. Topic-log objects are written once and
  never modified, which keeps the mesh inside the guarantees that actually hold:
  a delta that has been written is visible to every subsequent list, and a
  retried write is idempotent because the key is derived from the delta's own
  stamp.

  Snapshots *are* overwritten, which is why they are a bootstrap optimisation
  rather than the source of truth — a graph that reads a stale snapshot still
  converges by replaying the topic log after it.
  """

  @behaviour Jido.Context.Store

  alias Jido.Context.S3

  @impl true
  def get(key, opts) do
    {config, credentials} = client(opts)
    S3.get_object(config, credentials, key)
  end

  @impl true
  def put(key, body, opts) do
    {config, credentials} = client(opts)
    S3.put_object(config, credentials, key, body, content_type: content_type(key))
  end

  @impl true
  def delete(key, opts) do
    {config, credentials} = client(opts)
    S3.delete_object(config, credentials, key)
  end

  @impl true
  def list(prefix, opts) do
    {config, credentials} = client(opts)
    S3.list_objects(config, credentials, prefix, after: opts[:after], limit: opts[:limit])
  end

  defp client(opts) do
    {S3.config(opts), S3.credentials(resolve_secrets(opts))}
  end

  # `{:system, "VAR"}` is accepted for credentials so they can be named in
  # config without the value itself living in a config file.
  defp resolve_secrets(opts) do
    Enum.map(opts, fn
      {key, {:system, var}} when key in [:access_key_id, :secret_access_key, :session_token] ->
        {key, System.get_env(var)}

      other ->
        other
    end)
  end

  defp content_type(key) do
    cond do
      String.ends_with?(key, ".json") -> "application/json"
      String.ends_with?(key, ".jsonl") -> "application/x-ndjson"
      true -> "application/octet-stream"
    end
  end
end
