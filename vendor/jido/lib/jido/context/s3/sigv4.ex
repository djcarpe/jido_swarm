defmodule Jido.Context.S3.SigV4 do
  @moduledoc """
  AWS Signature Version 4 signing, in terms of `:crypto` alone.

  Jido does not depend on an AWS SDK. Signing is about a hundred lines of
  hashing and string concatenation, and the alternative is a dependency tree
  larger than Jido itself for one HTTP header.

  The implementation follows the
  [SigV4 specification](https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_sigv4-signing-elements.html)
  and is checked against AWS's own published worked example in the test suite,
  which is the only way to have any confidence in a signing implementation.

  ## S3-specific choices

  * `x-amz-content-sha256` carries the payload hash and is always signed. S3
    requires it; most other services do not use it.
  * The canonical URI is single-encoded. S3 is the exception to SigV4's
    normal double-encoding rule, because an object key may legitimately contain
    characters that normalization would change.
  """

  @algorithm "AWS4-HMAC-SHA256"
  @service "s3"

  @typedoc "Credentials. `:session_token` is set for temporary credentials."
  @type credentials :: %{
          required(:access_key_id) => String.t(),
          required(:secret_access_key) => String.t(),
          optional(:session_token) => String.t() | nil
        }

  @typedoc "A request to sign. `headers` must already contain `host`."
  @type request :: %{
          method: :get | :put | :delete | :head | :post,
          path: String.t(),
          query: [{String.t(), String.t()}],
          headers: [{String.t(), String.t()}],
          body: binary()
        }

  @doc """
  Signs a request, returning its headers with `authorization`, `x-amz-date` and
  `x-amz-content-sha256` added.

  `now` is a `{{y, m, d}, {h, mi, s}}` UTC tuple, injectable so the test suite
  can reproduce AWS's worked example exactly.
  """
  @spec sign(request(), credentials(), String.t(), :calendar.datetime()) ::
          [{String.t(), String.t()}]
  def sign(request, credentials, region, now \\ :calendar.universal_time()) do
    amz_date = amz_date(now)
    date_stamp = String.slice(amz_date, 0, 8)
    payload_hash = hex_sha256(request.body)

    headers =
      request.headers
      |> put_header("x-amz-date", amz_date)
      |> put_header("x-amz-content-sha256", payload_hash)
      |> maybe_put_session_token(credentials)

    {canonical_headers, signed_headers} = canonicalize_headers(headers)

    canonical_request =
      Enum.join(
        [
          method_string(request.method),
          canonical_uri(request.path),
          canonical_query(request.query),
          canonical_headers,
          signed_headers,
          payload_hash
        ],
        "\n"
      )

    scope = Enum.join([date_stamp, region, @service, "aws4_request"], "/")

    string_to_sign =
      Enum.join([@algorithm, amz_date, scope, hex_sha256(canonical_request)], "\n")

    signature =
      credentials
      |> signing_key(date_stamp, region)
      |> hmac(string_to_sign)
      |> Base.encode16(case: :lower)

    authorization =
      "#{@algorithm} Credential=#{credentials.access_key_id}/#{scope}, " <>
        "SignedHeaders=#{signed_headers}, Signature=#{signature}"

    put_header(headers, "authorization", authorization)
  end

  @doc """
  Derives the SigV4 signing key.

  Exposed because AWS publishes test vectors for this step alone, and a signing
  key that is wrong here is wrong everywhere downstream.
  """
  @spec signing_key(credentials(), String.t(), String.t()) :: binary()
  def signing_key(credentials, date_stamp, region) do
    ("AWS4" <> credentials.secret_access_key)
    |> hmac(date_stamp)
    |> hmac(region)
    |> hmac(@service)
    |> hmac("aws4_request")
  end

  @doc """
  Percent-encodes a string the way SigV4 requires.

  Unreserved characters are `A-Za-z0-9-_.~`; everything else becomes uppercase
  `%XX`. Note that a space is `%20`, never `+` — this is not form encoding.

      iex> Jido.Context.S3.SigV4.uri_encode("a b/c~d")
      "a%20b%2Fc~d"

      iex> Jido.Context.S3.SigV4.uri_encode("a/b", skip_slash: true)
      "a/b"
  """
  @spec uri_encode(String.t(), keyword()) :: String.t()
  def uri_encode(string, opts \\ []) do
    skip_slash? = Keyword.get(opts, :skip_slash, false)

    for <<byte <- string>>, into: "" do
      cond do
        unreserved?(byte) -> <<byte>>
        byte == ?/ and skip_slash? -> "/"
        true -> "%" <> Base.encode16(<<byte>>, case: :upper)
      end
    end
  end

  defp unreserved?(b)
       when b in ?A..?Z or b in ?a..?z or b in ?0..?9 or b in [?-, ?_, ?., ?~],
       do: true

  defp unreserved?(_), do: false

  # S3 signs the path single-encoded. `/` separates segments and stays literal.
  defp canonical_uri(""), do: "/"
  defp canonical_uri("/" <> _ = path), do: uri_encode(path, skip_slash: true)
  defp canonical_uri(path), do: canonical_uri("/" <> path)

  defp canonical_query([]), do: ""

  defp canonical_query(query) do
    query
    |> Enum.map(fn {k, v} -> {uri_encode(to_string(k)), uri_encode(to_string(v))} end)
    |> Enum.sort()
    |> Enum.map_join("&", fn {k, v} -> k <> "=" <> v end)
  end

  # Header names lowercase, values whitespace-trimmed, sorted by name. Duplicate
  # names would need comma-joining; this client never emits any, and the sort
  # would silently mis-sign if one appeared, so they are rejected instead.
  defp canonicalize_headers(headers) do
    normalized =
      headers
      |> Enum.map(fn {k, v} -> {String.downcase(to_string(k)), String.trim(to_string(v))} end)
      |> Enum.sort_by(&elem(&1, 0))

    names = Enum.map(normalized, &elem(&1, 0))

    if names != Enum.uniq(names) do
      raise ArgumentError, "duplicate header names cannot be signed: #{inspect(names)}"
    end

    canonical = Enum.map_join(normalized, "", fn {k, v} -> "#{k}:#{v}\n" end)
    {canonical, Enum.join(names, ";")}
  end

  defp maybe_put_session_token(headers, %{session_token: token})
       when is_binary(token) and token != "" do
    put_header(headers, "x-amz-security-token", token)
  end

  defp maybe_put_session_token(headers, _), do: headers

  defp put_header(headers, name, value) do
    List.keystore(headers, name, 0, {name, value})
  end

  defp method_string(method), do: method |> Atom.to_string() |> String.upcase()

  defp amz_date({{y, m, d}, {h, mi, s}}) do
    :io_lib.format(~c"~4..0B~2..0B~2..0BT~2..0B~2..0B~2..0BZ", [y, m, d, h, mi, s])
    |> IO.iodata_to_binary()
  end

  defp hex_sha256(data), do: :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)

  defp hmac(key, data), do: :crypto.mac(:hmac, :sha256, key, data)
end
