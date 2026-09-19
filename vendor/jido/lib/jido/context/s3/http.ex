defmodule Jido.Context.S3.HTTP do
  @moduledoc """
  The HTTP transport used to reach S3.

  Split out as a behaviour for two reasons: it lets the S3 store be tested
  against a stub without a network or a bucket, and it lets an application that
  already runs Finch, Req or Hackney reuse its connection pool instead of
  paying for a second one.

      config :jido, Jido.Context, s3_http_client: MyApp.ReqS3Client

  The default, `Jido.Context.S3.HTTP.Httpc`, uses OTP's own `:httpc` so that
  Jido gains no dependency for this.
  """

  @type method :: :get | :put | :delete | :head | :post
  @type headers :: [{String.t(), String.t()}]

  @doc """
  Performs a request.

  Implementations must return the response body as a binary and must not raise
  on a non-2xx status — an HTTP error is a value here, since S3 signals
  `:not_found` with a 404.
  """
  @callback request(method(), url :: String.t(), headers(), body :: binary(), opts :: keyword()) ::
              {:ok, status :: non_neg_integer(), headers(), binary()} | {:error, term()}

  @doc "The configured client module."
  @spec client() :: module()
  def client do
    :jido
    |> Application.get_env(Jido.Context, [])
    |> Keyword.get(:s3_http_client, Jido.Context.S3.HTTP.Httpc)
  end
end

defmodule Jido.Context.S3.HTTP.Httpc do
  @moduledoc """
  `Jido.Context.S3.HTTP` over OTP's `:httpc`.

  `:httpc` is in every OTP release, which is the point: streaming a knowledge
  graph to object storage should not oblige an application to adopt an HTTP
  client it did not otherwise want.

  Requests run through a named profile so Jido's connection pool and options
  stay separate from the default profile an application may be configuring for
  its own purposes. TLS verification uses OTP's built-in CA store
  (`:public_key.cacerts_get/0`), so certificates are actually checked rather
  than accepted blindly.
  """

  @behaviour Jido.Context.S3.HTTP

  @profile :jido_context_s3

  @impl true
  def request(method, url, headers, body, opts) do
    ensure_profile()

    timeout = Keyword.get(opts, :timeout, 30_000)
    charlist_headers = Enum.map(headers, fn {k, v} -> {to_charlist(k), to_charlist(v)} end)

    http_request = build_request(method, url, charlist_headers, body, headers)

    http_opts = [
      timeout: timeout,
      connect_timeout: Keyword.get(opts, :connect_timeout, 10_000),
      ssl: ssl_opts(url)
    ]

    case :httpc.request(method, http_request, http_opts, [body_format: :binary], @profile) do
      {:ok, {{_version, status, _reason}, resp_headers, resp_body}} ->
        {:ok, status, decode_headers(resp_headers), resp_body}

      {:ok, {status, resp_body}} ->
        {:ok, status, [], resp_body}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # `:httpc` takes a 4-tuple with a content type for requests that carry a body
  # and a 2-tuple for those that do not.
  defp build_request(method, url, charlist_headers, body, headers)
       when method in [:put, :post] do
    content_type =
      headers
      |> Enum.find_value(fn {k, v} -> if String.downcase(k) == "content-type", do: v end)
      |> Kernel.||("application/octet-stream")

    # The content-type is passed positionally, so leaving it in the header list
    # as well would send it twice — and the signature covers only one of them.
    without_ct =
      Enum.reject(charlist_headers, fn {k, _} ->
        k |> to_string() |> String.downcase() == "content-type"
      end)

    {to_charlist(url), without_ct, to_charlist(content_type), body}
  end

  defp build_request(_method, url, charlist_headers, _body, _headers) do
    {to_charlist(url), charlist_headers}
  end

  defp ssl_opts(url) do
    if String.starts_with?(url, "https://") do
      [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        depth: 3,
        customize_hostname_check: [
          match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
        ]
      ]
    else
      []
    end
  end

  defp decode_headers(headers) do
    Enum.map(headers, fn {k, v} -> {k |> to_string() |> String.downcase(), to_string(v)} end)
  end

  # `:inets` may not be started in a release that trimmed it, and the profile is
  # created lazily so nothing is paid for by applications that never use S3.
  defp ensure_profile do
    case :inets.start(:httpc, profile: @profile) do
      {:ok, _pid} -> configure_profile()
      {:error, {:already_started, _}} -> :ok
      {:error, _} -> start_inets_then_profile()
    end
  end

  defp start_inets_then_profile do
    {:ok, _} = Application.ensure_all_started(:inets)

    case :inets.start(:httpc, profile: @profile) do
      {:ok, _pid} ->
        configure_profile()

      {:error, {:already_started, _}} ->
        :ok

      {:error, reason} ->
        raise "could not start the #{inspect(@profile)} httpc profile: #{inspect(reason)}"
    end
  end

  defp configure_profile do
    :httpc.set_options([keep_alive_timeout: 60_000, max_keep_alive_length: 10], @profile)
    :ok
  end
end
