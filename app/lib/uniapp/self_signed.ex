defmodule Uniapp.SelfSigned do
  @moduledoc """
  Generates an ephemeral test PKI (root CA + server leaf, P-256) for the TLS
  server probe, using OTP's `:public_key.pkix_test_data/1`.
  """

  @doc "Returns ssl options `[cert: der, key: {:ECPrivateKey, der}, cacerts: [der]]` for `:ssl.listen/2`."
  def server_opts do
    gen = fn -> :public_key.generate_key({:namedCurve, :secp256r1}) end

    %{server_config: server} =
      :public_key.pkix_test_data(%{
        server_chain: %{root: [key: gen.(), digest: :sha256], intermediates: [], peer: [key: gen.(), digest: :sha256]},
        client_chain: %{root: [key: gen.(), digest: :sha256], intermediates: [], peer: [key: gen.(), digest: :sha256]}
      })

    Keyword.take(server, [:cert, :key, :cacerts])
  end
end
