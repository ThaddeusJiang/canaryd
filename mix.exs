defmodule Canaryd.MixProject do
  use Mix.Project

  def project do
    [
      app: :canaryd,
      version: "0.4.3",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      escript: [main_module: Canaryd.CLI, name: "canaryd"],
      releases: releases(),
      description: description(),
      package: package(),
      deps: deps(),
      source_url: "https://github.com/ThaddeusJiang/canaryd",
      docs: [main: "readme", extras: ["README.md"]]
    ]
  end

  def application do
    [extra_applications: [:logger]] ++ application_module()
  end

  defp deps do
    [
      {:burrito, "1.6.0", only: :prod, runtime: false},
      {:ex_doc, "0.40.3", only: :dev, runtime: false, optional: true}
    ]
  end

  defp releases do
    [
      canaryd: [
        steps: [:assemble, &Burrito.wrap/1],
        burrito: [
          targets: [
            macos_arm64: [os: :darwin, cpu: :aarch64],
            macos_x86_64: [os: :darwin, cpu: :x86_64]
          ]
        ]
      ]
    ]
  end

  defp application_module,
    do: if(Mix.env() == :prod, do: [mod: {Canaryd.Application, []}], else: [])

  defp description do
    """
    Canary in the coal mine for your Mac. Detects overheating and apps that
    are alive but silently dead (process running, function stopped) via
    synthetic probes. Self-heals with quiet restarts; only nags you when blocked.
    """
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/ThaddeusJiang/canaryd"},
      files: ~w(lib priv mix.exs README.md LICENSE)
    ]
  end
end
