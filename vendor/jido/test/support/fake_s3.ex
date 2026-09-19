defmodule JidoTest.FakeS3 do
  @moduledoc """
  An in-process S3 implementation, used as a `Jido.Context.S3.HTTP` client.

  This is what lets the object-storage path — key layout, prefix scoping,
  ListObjectsV2 XML, continuation tokens, `start-after` tailing and the whole
  mesh riding on top of them — be tested without a bucket or a network.

  It deliberately does *not* verify signatures; `Jido.Context.S3.SigV4Test`
  proves signing against AWS's published vectors, and duplicating that here
  would only prove this module agrees with itself. It does assert that a signed
  `authorization` header arrived at all, so an unsigned request cannot pass
  unnoticed.

  Pages are small on purpose (`@page_size`) so that any listing of more than a
  couple of objects exercises continuation.
  """

  @behaviour Jido.Context.S3.HTTP

  use Agent

  @page_size 2

  def start_link(opts \\ []) do
    Agent.start_link(fn -> %{objects: %{}, requests: []} end,
      name: Keyword.get(opts, :name, __MODULE__)
    )
  end

  @doc "Every request the client has made, oldest first."
  def requests(name \\ __MODULE__), do: Agent.get(name, & &1.requests) |> Enum.reverse()

  @doc "The raw object map, for assertions about key layout."
  def objects(name \\ __MODULE__), do: Agent.get(name, & &1.objects)

  @doc "Removes every object."
  def reset(name \\ __MODULE__),
    do: Agent.update(name, fn _ -> %{objects: %{}, requests: []} end)

  @impl true
  def request(method, url, headers, body, _opts) do
    unless List.keyfind(headers, "authorization", 0) do
      raise "FakeS3 received an unsigned request: #{method} #{url}"
    end

    uri = URI.parse(url)
    query = URI.decode_query(uri.query || "")
    path = URI.decode(uri.path)

    Agent.update(__MODULE__, fn state ->
      %{state | requests: [{method, path, query} | state.requests]}
    end)

    dispatch(method, path, query, body)
  end

  # ListObjectsV2 is a GET on the bucket itself, distinguished by list-type=2.
  defp dispatch(:get, path, %{"list-type" => "2"} = query, _body) do
    prefix = Map.get(query, "prefix", "")
    start_after = Map.get(query, "start-after")
    token = Map.get(query, "continuation-token")
    bucket_prefix = String.trim_leading(path, "/")

    after_key =
      [token, start_after]
      |> Enum.reject(&is_nil/1)
      |> Enum.max(fn -> nil end)

    all =
      __MODULE__
      |> objects()
      |> Map.keys()
      |> Enum.map(&strip_bucket(&1, bucket_prefix))
      |> Enum.filter(&String.starts_with?(&1, prefix))
      |> Enum.filter(fn key -> is_nil(after_key) or key > after_key end)
      |> Enum.sort()

    {page, rest} = Enum.split(all, @page_size)
    truncated? = rest != []

    {:ok, 200, [], list_xml(page, truncated?, List.last(page))}
  end

  defp dispatch(:get, path, _query, _body) do
    case Map.fetch(objects(), path) do
      {:ok, body} -> {:ok, 200, [], body}
      :error -> {:ok, 404, [], "<Error><Code>NoSuchKey</Code></Error>"}
    end
  end

  defp dispatch(:put, path, _query, body) do
    Agent.update(__MODULE__, fn state ->
      %{state | objects: Map.put(state.objects, path, body)}
    end)

    {:ok, 200, [], ""}
  end

  defp dispatch(:delete, path, _query, _body) do
    Agent.update(__MODULE__, fn state ->
      %{state | objects: Map.delete(state.objects, path)}
    end)

    {:ok, 204, [], ""}
  end

  # Object paths arrive as `/bucket/key...` in path style. The listing's own
  # path is `/bucket`, so stripping it leaves the key the client asked about.
  defp strip_bucket(object_path, bucket_prefix) do
    object_path
    |> String.trim_leading("/")
    |> String.trim_leading(bucket_prefix)
    |> String.trim_leading("/")
  end

  defp list_xml(keys, truncated?, last_key) do
    contents =
      Enum.map_join(keys, "", fn key ->
        "<Contents><Key>#{escape(key)}</Key><Size>1</Size></Contents>"
      end)

    token =
      if truncated? and last_key do
        "<NextContinuationToken>#{escape(last_key)}</NextContinuationToken>"
      else
        ""
      end

    """
    <?xml version="1.0" encoding="UTF-8"?>
    <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
      <Name>bucket</Name>
      <IsTruncated>#{truncated?}</IsTruncated>
      #{token}
      #{contents}
    </ListBucketResult>
    """
  end

  defp escape(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end
end
