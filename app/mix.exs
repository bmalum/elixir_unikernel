defmodule Uniapp.MixProject do
  use Mix.Project

  def project do
    [
      app: :uniapp,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: [],
      releases: releases()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto, :ssl, :public_key, :inets, :iex],
      mod: {Uniapp.Application, []}
    ]
  end

  defp erts do
    case System.get_env("UNIAPP_ERTS") do
      nil -> true
      root -> root |> Path.join("erts-*") |> Path.wildcard() |> List.first() || raise "no erts-* in #{root}"
    end
  end

  defp releases do
    [
      uniapp: [
        include_executables_for: [],
        # UNIAPP_ERTS points at a (cross-compiled) OTP root; Mix then takes both
        # ERTS and the OTP applications from there. Unset = host OTP.
        include_erts: erts(),
        strip_beams: true,
        # bin/uniapp is never used: /init starts beam.smp directly.
        steps: [:assemble, &Uniapp.ReleaseSteps.prune/1]
      ]
    ]
  end
end
