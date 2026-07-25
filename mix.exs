defmodule Canaryd.MixProject do
  use Mix.Project

  def project do
    [
      app: :canaryd,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      escript: [main_module: Canaryd.CLI, name: "canaryd"],
      description: description(),
      package: package(),
      deps: deps(),
      source_url: "https://github.com/ThaddeusJiang/canaryd",
      docs: [main: "readme", extras: ["README.md"]]
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [{:ex_doc, "~> 0.34", only: :dev, runtime: false, optional: true}]
  end

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
      files: ~w(lib mix.exs README.md LICENSE)
    ]
  end
end
