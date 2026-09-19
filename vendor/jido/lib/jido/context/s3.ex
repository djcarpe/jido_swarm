defmodule Jido.Context.S3 do
  @moduledoc """
  A small S3 client: the five operations a context mesh needs, and nothing else.

  `GET`, `PUT`, `DELETE` and a paginated `ListObjectsV2`. Requests are signed
  with `Jido.Context.S3.SigV4` and carried by `Jido.Context.S3.HTTP`, so Jido
  adds no dependency for either.

  It speaks to anything with an S3 API — AWS, MinIO, Cloudflare R2, Ceph,
  Garage — by pointing `:endpoint` at it.

  ## Configuration

      [
        bucket: "agent-graphs",           # required
        prefix: "mesh/prod",              # optional key prefix
        region: "us-east-1",              # default "us-east-1"
        endpoint: "http://minio:9000",    # default: AWS for the region
        access_key_id: "...",             # default: AWS_ACCESS_KEY_ID
        secret_access_key: "...",         # default: AWS_SECRET_ACCESS_KEY
        session_token: "...",             # default: AWS_SESSION_TOKEN
        path_style: true                  # default: true for a custom endpoint
      ]

  Credentials fall back to the standard environment variables, so the usual
  deployment story — an instance profile exporting them, or a `.env` — works
  without naming them in config. They are read at call time rather than at
  boot, so rotated credentials are picked up without a restart.

  ## Addressing

  AWS wants virtual-hosted style (`bucket.s3.region.amazonaws.com/key`); most
  self-hosted implementations want path style (`endpoint/bucket/key`). The
  default follows that split, and `:path_style` overrides it either way.
  """

  alias Jido.Context.S3.HTTP
  alias Jido.Context.S3.SigV4

  defstruct [
    :bucket,
    :region,
    :endpoint,
    :prefix,
    :path_style,
    :http_opts
  ]

  @type t :: %__MODULE__{
          bucket: String.t(),
          region: String.t(),
          endpoint: String.t(),
          prefix: String.t() | nil,
          path_style: boolean(),
          http_opts: keyword()
        }

  @doc """
  Builds a client config from options.

  Raises when `:bucket` is missing — an S3 store with no bucket is a
  misconfiguration that should fail at startup, not on the first write.
  """
  @spec config(keyword()) :: t()
  def config(opts) do
    bucket = Keyword.fetch!(opts, :bucket)
    region = Keyword.get(opts, :region, "us-east-1")
    endpoint = Keyword.get(opts, :endpoint) || "https://s3.#{region}.amazonaws.com"
    custom_endpoint? = not is_nil(Keyword.get(opts, :endpoint))

    %__MODULE__{
      bucket: bucket,
      region: region,
      endpoint: String.trim_trailing(endpoint, "/"),
      prefix: opts |> Keyword.get(:prefix) |> normalize_prefix(),
      path_style: Keyword.get(opts, :path_style, custom_endpoint?),
      http_opts: Keyword.get(opts, :http_opts, [])
    }
  end

  defp normalize_prefix(nil), do: nil
  defp normalize_prefix(""), do: nil

  defp normalize_prefix(prefix),
    do: prefix |> String.trim("/") |> then(&if &1 == "", do: nil, else: &1)

  @doc """
  Reads credentials, preferring explicit options over the environment.
  """
  @spec credentials(keyword()) :: SigV4.credentials()
  def credentials(opts) do
    %{
      access_key_id:
        Keyword.get(opts, :access_key_id) || System.get_env("AWS_ACCESS_KEY_ID") || "",
      secret_access_key:
        Keyword.get(opts, :secret_access_key) || System.get_env("AWS_SECRET_ACCESS_KEY") || "",
      session_token: Keyword.get(opts, :session_token) || System.get_env("AWS_SESSION_TOKEN")
    }
  end

  @doc """
  Fetches an object. `:not_found` on a 404.
  """
  @spec get_object(t(), SigV4.credentials(), String.t()) ::
          {:ok, binary()} | :not_found | {:error, term()}
  def get_object(config, credentials, key) do
    case request(config, credentials, :get, object_path(config, key), [], "") do
      {:ok, status, _headers, body} when status in 200..299 -> {:ok, body}
      {:ok, 404, _headers, _body} -> :not_found
      {:ok, status, _headers, body} -> {:error, {:s3_error, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Writes an object."
  @spec put_object(t(), SigV4.credentials(), String.t(), binary(), keyword()) ::
          :ok | {:error, term()}
  def put_object(config, credentials, key, body, opts \\ []) do
    headers = [{"content-type", Keyword.get(opts, :content_type, "application/octet-stream")}]

    case request(config, credentials, :put, object_path(config, key), [], body, headers) do
      {:ok, status, _headers, _body} when status in 200..299 -> :ok
      {:ok, status, _headers, resp} -> {:error, {:s3_error, status, resp}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Deletes an object. A 404 counts as success."
  @spec delete_object(t(), SigV4.credentials(), String.t()) :: :ok | {:error, term()}
  def delete_object(config, credentials, key) do
    case request(config, credentials, :delete, object_path(config, key), [], "") do
      {:ok, status, _headers, _body} when status in 200..299 or status == 404 -> :ok
      {:ok, status, _headers, body} -> {:error, {:s3_error, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Lists keys under `prefix`, following continuation tokens to completion.

  Returned keys have the client's configured `:prefix` stripped, so callers see
  the same key space they wrote through `put_object/5`.

  ## Options

  * `:after` — S3's `start-after`; returns only keys greater than this one.
    This is what makes a topic log tailable: a poller remembers the last key it
    processed and asks only for what came later.
  * `:limit` — stop after this many keys.
  """
  @spec list_objects(t(), SigV4.credentials(), String.t(), keyword()) ::
          {:ok, [String.t()]} | {:error, term()}
  def list_objects(config, credentials, prefix, opts \\ []) do
    full_prefix = scoped(config, prefix)
    start_after = opts[:after] && scoped(config, opts[:after])
    limit = opts[:limit]

    do_list(config, credentials, full_prefix, start_after, limit, nil, [])
  end

  defp do_list(config, credentials, prefix, start_after, limit, token, acc) do
    query =
      [{"list-type", "2"}, {"prefix", prefix}]
      |> maybe_put("start-after", start_after)
      |> maybe_put("continuation-token", token)
      |> maybe_put("max-keys", limit && Integer.to_string(min(limit, 1000)))

    case request(config, credentials, :get, bucket_path(config), query, "") do
      {:ok, status, _headers, body} when status in 200..299 ->
        {keys, next} = parse_list_result(body)
        acc = acc ++ Enum.map(keys, &unscope(config, &1))

        cond do
          limit && length(acc) >= limit -> {:ok, Enum.take(acc, limit)}
          next -> do_list(config, credentials, prefix, start_after, limit, next, acc)
          true -> {:ok, acc}
        end

      {:ok, status, _headers, body} ->
        {:error, {:s3_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_put(query, _key, nil), do: query
  defp maybe_put(query, key, value), do: query ++ [{key, value}]

  @doc """
  Extracts keys and the continuation token from a ListObjectsV2 response.

  The response is XML and Jido has no XML parser, which for this one shape is
  the right trade: `<Key>` elements in a ListObjectsV2 body carry XML-escaped
  text and no attributes or nesting, so pulling them out with a pattern is
  exact rather than approximate. Anything more structural than this would need
  a real parser.

  Exposed for testing against captured S3 responses.
  """
  @spec parse_list_result(binary()) :: {[String.t()], String.t() | nil}
  def parse_list_result(xml) do
    keys =
      ~r|<Key>(.*?)</Key>|s
      |> Regex.scan(xml, capture: :all_but_first)
      |> Enum.map(fn [key] -> unescape_xml(key) end)

    truncated? =
      case Regex.run(~r|<IsTruncated>(.*?)</IsTruncated>|s, xml, capture: :all_but_first) do
        ["true"] -> true
        _ -> false
      end

    token =
      case Regex.run(~r|<NextContinuationToken>(.*?)</NextContinuationToken>|s, xml,
             capture: :all_but_first
           ) do
        [token] when token != "" -> unescape_xml(token)
        _ -> nil
      end

    {keys, if(truncated?, do: token, else: nil)}
  end

  # `&amp;` must be last: unescaping it first would let `&amp;lt;` become `<`.
  defp unescape_xml(text) do
    text
    |> String.replace("&quot;", "\"")
    |> String.replace("&apos;", "'")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&amp;", "&")
  end

  @doc "The fully-qualified key for `key`, including the configured prefix."
  @spec scoped(t(), String.t()) :: String.t()
  def scoped(%__MODULE__{prefix: nil}, key), do: key
  def scoped(%__MODULE__{prefix: prefix}, key), do: prefix <> "/" <> key

  defp unscope(%__MODULE__{prefix: nil}, key), do: key

  defp unscope(%__MODULE__{prefix: prefix}, key) do
    case key do
      <<^prefix::binary, "/", rest::binary>> -> rest
      other -> other
    end
  end

  defp object_path(config, key) do
    scoped = scoped(config, key)

    if config.path_style do
      "/" <> config.bucket <> "/" <> scoped
    else
      "/" <> scoped
    end
  end

  defp bucket_path(config) do
    if config.path_style, do: "/" <> config.bucket, else: "/"
  end

  defp request(config, credentials, method, path, query, body, extra_headers \\ []) do
    host = host_for(config)

    headers =
      [{"host", host}] ++ extra_headers

    signed =
      SigV4.sign(
        %{method: method, path: path, query: query, headers: headers, body: body},
        credentials,
        config.region
      )

    url = url_for(config, host, path, query)

    HTTP.client().request(method, url, signed, body, config.http_opts)
  end

  # The signed `host` header and the host actually connected to must agree, so
  # both are derived here from one decision about addressing style.
  defp host_for(config) do
    %URI{host: host, port: port, scheme: scheme} = URI.parse(config.endpoint)

    base =
      if config.path_style do
        host
      else
        config.bucket <> "." <> host
      end

    if default_port?(scheme, port), do: base, else: "#{base}:#{port}"
  end

  defp default_port?("https", 443), do: true
  defp default_port?("http", 80), do: true
  defp default_port?(_, nil), do: true
  defp default_port?(_, _), do: false

  defp url_for(config, host, path, query) do
    %URI{scheme: scheme} = URI.parse(config.endpoint)

    encoded_path = SigV4.uri_encode(path, skip_slash: true)

    query_string =
      case query do
        [] ->
          ""

        query ->
          "?" <>
            Enum.map_join(query, "&", fn {k, v} ->
              SigV4.uri_encode(to_string(k)) <> "=" <> SigV4.uri_encode(to_string(v))
            end)
      end

    "#{scheme}://#{host}#{encoded_path}#{query_string}"
  end
end
