defmodule Canaryd.Paths do
  @moduledoc false

  @doc false
  def support_dir do
    Path.join([home_dir(), "Library", "Application Support", "canaryd"])
  end

  @doc false
  def launch_agents_dir do
    Path.join([home_dir(), "Library", "LaunchAgents"])
  end

  @doc false
  def simulator_devices_dir do
    Path.join([home_dir(), "Library", "Developer", "CoreSimulator", "Devices"])
  end

  @doc false
  def clean_clip_history_dir do
    Path.join([
      home_dir(),
      "Library",
      "Application Support",
      "com.antiless.cleanclip.mac",
      "PrivateData",
      "HistoryItemContents"
    ])
  end

  defp home_dir do
    case System.get_env("HOME") do
      home when is_binary(home) and home != "" -> Path.expand(home)
      _home -> System.user_home!()
    end
  end
end
