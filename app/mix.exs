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
      extra_applications: [:logger, :crypto, :ssl, :public_key, :iex],
      mod: {Uniapp.Application, []}
    ]
  end

  defp releases do
    [
      uniapp: [
        include_executables_for: [],
        include_erts: true,
        strip_beams: true,
        # bin/uniapp is never used: /init starts beam.smp directly.
        steps: [:assemble, &Uniapp.ReleaseSteps.prune/1]
      ]
    ]
  end
end
