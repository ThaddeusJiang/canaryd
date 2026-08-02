defmodule Canaryd.Setup do
  @moduledoc """
  Self-installing launchd agent. launchd is an implementation detail:
  users never touch plist files. Every CLI invocation ensures the agent
  is present and loaded; if the user deletes it, the next run heals it.
  """

  @label "com.thaddeusjiang.canaryd"
  @thermal_label "com.thaddeusjiang.canaryd.thermal"

  alias Canaryd.{Duration, NotificationHelper, Paths}

  def label, do: @label
  def thermal_label, do: @thermal_label

  @doc false
  def agent_specs(escript_path) do
    [
      %{
        label: @label,
        command: "check",
        interval: Duration.minutes(5),
        escript_path: escript_path
      },
      %{
        label: @thermal_label,
        command: "thermal-check",
        interval: Duration.minutes(1),
        escript_path: escript_path
      }
    ]
  end

  @doc "Idempotent. Safe to call on every CLI run."
  def ensure_installed do
    agents = configured_agents()

    with :ok <- NotificationHelper.ensure_installed() do
      cond do
        Enum.any?(agents, &(not File.exists?(plist_path(&1.label)))) ->
          install_agents(agents)

        Enum.any?(agents, &(not loaded?(&1.label))) ->
          bootstrap(agents)

        true ->
          :ok
      end
    end
  end

  def install do
    agents = configured_agents()

    with :ok <- NotificationHelper.ensure_installed() do
      install_agents(agents)
    end
  end

  defp install_agents(agents) do
    File.mkdir_p!(Path.dirname(plist_path(@label)))
    File.mkdir_p!(log_dir())

    Enum.each(agents, fn agent ->
      File.write!(plist_path(agent.label), agent_plist(agent))
    end)

    bootstrap(agents)
  end

  def uninstall do
    Enum.each(configured_agents(), fn agent ->
      if loaded?(agent.label), do: bootout(agent.label)
      File.rm(plist_path(agent.label))
    end)

    NotificationHelper.remove()
    :ok
  end

  defp bootstrap(agents) do
    Enum.each(agents, &bootout(&1.label))

    Enum.reduce_while(agents, :ok, fn agent, :ok ->
      args = ["bootstrap", "gui/#{uid()}", plist_path(agent.label)]

      case System.cmd("launchctl", args, stderr_to_stdout: true) do
        {_, 0} -> {:cont, :ok}
        {error, _status} -> {:halt, {:error, error}}
      end
    end)
  end

  defp bootout(label) do
    System.cmd("launchctl", ["bootout", "gui/#{uid()}/#{label}"], stderr_to_stdout: true)
    :ok
  end

  defp loaded?(label) do
    case System.cmd("launchctl", ["list", label], stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  end

  defp uid do
    {out, 0} = System.cmd("id", ["-u"], stderr_to_stdout: true)
    String.trim(out)
  end

  defp plist_path(label) do
    Path.join(Paths.launch_agents_dir(), "#{label}.plist")
  end

  defp log_dir, do: Canaryd.Store.dir()

  defp configured_agents, do: agent_specs(executable_path())

  @doc false
  def executable_path(
        burrito_path \\ System.get_env("__BURRITO_BIN_PATH"),
        escript_name \\ :escript.script_name()
      )

  def executable_path(burrito_path, _escript_name)
      when is_binary(burrito_path) and burrito_path != "" do
    Path.expand(burrito_path)
  end

  def executable_path(_burrito_path, escript_name) do
    case escript_name do
      ~c"" -> Path.expand("canaryd")
      name -> Path.expand(List.to_string(name))
    end
  end

  # escript shebang is `#!/usr/bin/env escript`, so erlang's bin must be on PATH
  defp erlang_bin do
    Path.join([:code.root_dir(), "bin"])
  end

  @doc false
  def agent_plist(agent) do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
      <key>Label</key>
      <string>#{agent.label}</string>
      <key>ProgramArguments</key>
      <array>
        <string>#{agent.escript_path}</string>
        <string>#{agent.command}</string>
      </array>
      <key>StartInterval</key>
      <integer>#{Duration.to_external(agent.interval, :second)}</integer>
      <key>RunAtLoad</key>
      <true/>
      <key>StandardOutPath</key>
      <string>#{log_dir()}/stdout.log</string>
      <key>StandardErrorPath</key>
      <string>#{log_dir()}/stderr.log</string>
      <key>EnvironmentVariables</key>
      <dict>
        <key>PATH</key>
        <string>#{erlang_bin()}:/usr/local/bin:/usr/bin:/bin</string>
      </dict>
    </dict>
    </plist>
    """
  end
end
