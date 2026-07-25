defmodule MacHealth.MixProject do
  use Mix.Project

  def project do
    [
      app: :mac_health,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      escript: [main_module: MacHealth.CLI, name: "mac_health"],
      deps: []
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end
end
