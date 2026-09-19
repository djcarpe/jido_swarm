defmodule Jido.Context.S3.SigV4Test do
  @moduledoc """
  Checked against the worked examples AWS publishes for S3 request signing.

  A signing implementation that is subtly wrong fails only against a real
  bucket, with an opaque 403, so these are literal reproductions of AWS's own
  documented requests and the exact signatures they expect.
  """

  use ExUnit.Case, async: true

  doctest Jido.Context.S3.SigV4

  alias Jido.Context.S3.SigV4

  # The credentials AWS uses throughout its signing documentation.
  @credentials %{
    access_key_id: "AKIAIOSFODNN7EXAMPLE",
    secret_access_key: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
    session_token: nil
  }
  @region "us-east-1"
  @date {{2013, 5, 24}, {0, 0, 0}}
  @host "examplebucket.s3.amazonaws.com"

  defp signature(headers) do
    {_, authorization} = List.keyfind(headers, "authorization", 0)
    [_, signature] = Regex.run(~r/Signature=([0-9a-f]+)/, authorization)
    signature
  end

  defp header(headers, name) do
    case List.keyfind(headers, name, 0) do
      {^name, value} -> value
      nil -> nil
    end
  end

  describe "AWS worked examples" do
    test "GET Object" do
      headers =
        SigV4.sign(
          %{
            method: :get,
            path: "/test.txt",
            query: [],
            headers: [{"host", @host}, {"range", "bytes=0-9"}],
            body: ""
          },
          @credentials,
          @region,
          @date
        )

      assert signature(headers) ==
               "f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41"

      assert header(headers, "x-amz-date") == "20130524T000000Z"

      assert header(headers, "x-amz-content-sha256") ==
               "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

      assert header(headers, "authorization") =~
               "Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request"

      assert header(headers, "authorization") =~
               "SignedHeaders=host;range;x-amz-content-sha256;x-amz-date"
    end

    test "PUT Object" do
      headers =
        SigV4.sign(
          %{
            method: :put,
            path: "/test$file.text",
            query: [],
            headers: [
              {"host", @host},
              {"date", "Fri, 24 May 2013 00:00:00 GMT"},
              {"x-amz-storage-class", "REDUCED_REDUNDANCY"}
            ],
            body: "Welcome to Amazon S3."
          },
          @credentials,
          @region,
          @date
        )

      assert signature(headers) ==
               "98ad721746da40c64f1a55b78f14c238d841ea1380cd77a1b5971af0ece108bd"

      # The payload hash AWS documents for this body.
      assert header(headers, "x-amz-content-sha256") ==
               "44ce7dd67c959e0d3524ffac1771dfbba87d2b6b4b4e99e42034a8b803f8b072"
    end

    test "GET Bucket (List Objects) - exercises canonical query ordering" do
      headers =
        SigV4.sign(
          %{
            method: :get,
            path: "/",
            # Deliberately out of order: the canonical form must sort them.
            query: [{"prefix", "J"}, {"max-keys", "2"}],
            headers: [{"host", @host}],
            body: ""
          },
          @credentials,
          @region,
          @date
        )

      assert signature(headers) ==
               "34b48302e7b5fa45bde8084f4b7868a86f0a534bc59db6670ed5711ef69dc6f7"
    end
  end

  describe "signing_key/3" do
    test "matches AWS's documented derivation" do
      # AWS publishes this chain for the iam service; the same four HMACs with
      # "s3" substituted is what `signing_key/3` computes, so this asserts the
      # structure by checking the value is stable and correctly shaped.
      key = SigV4.signing_key(@credentials, "20130524", @region)

      assert byte_size(key) == 32

      # Recomputing the published chain independently must agree.
      expected =
        ["AWS4" <> @credentials.secret_access_key, "20130524", @region, "s3", "aws4_request"]
        |> Enum.reduce(fn data, acc -> :crypto.mac(:hmac, :sha256, acc, data) end)

      assert key == expected
    end
  end

  describe "uri_encode/2" do
    test "percent-encodes everything outside the unreserved set" do
      assert SigV4.uri_encode("a b") == "a%20b"
      assert SigV4.uri_encode("a/b") == "a%2Fb"
      assert SigV4.uri_encode("a~b-c_d.e") == "a~b-c_d.e"
      assert SigV4.uri_encode("$") == "%24"
    end

    test "uses %20 for a space, never +" do
      refute SigV4.uri_encode("a b") =~ "+"
    end

    test "leaves slashes alone for a path" do
      assert SigV4.uri_encode("/a/b c", skip_slash: true) == "/a/b%20c"
    end

    test "uppercases the hex digits" do
      assert SigV4.uri_encode("ä") == "%C3%A4"
    end
  end

  describe "session tokens" do
    test "a temporary credential's token is signed" do
      headers =
        SigV4.sign(
          %{method: :get, path: "/x", query: [], headers: [{"host", @host}], body: ""},
          Map.put(@credentials, :session_token, "TOKEN123"),
          @region,
          @date
        )

      assert header(headers, "x-amz-security-token") == "TOKEN123"
      assert header(headers, "authorization") =~ "x-amz-security-token"
    end

    test "no token header is added when there is no session token" do
      headers =
        SigV4.sign(
          %{method: :get, path: "/x", query: [], headers: [{"host", @host}], body: ""},
          @credentials,
          @region,
          @date
        )

      assert header(headers, "x-amz-security-token") == nil
    end
  end

  test "duplicate header names are rejected rather than silently mis-signed" do
    assert_raise ArgumentError, ~r/duplicate header/, fn ->
      SigV4.sign(
        %{
          method: :get,
          path: "/x",
          query: [],
          headers: [{"host", @host}, {"Host", @host}],
          body: ""
        },
        @credentials,
        @region,
        @date
      )
    end
  end
end
