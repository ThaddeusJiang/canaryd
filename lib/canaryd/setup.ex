defmodule Canaryd.Setup do
  @moduledoc """
  Manages launchd agents for explicit CLI start and stop requests.
  launchd is an implementation detail: users never touch plist files.
  """

  @label "com.thaddeusjiang.canaryd"
  @build_cleanup_label "com.thaddeusjiang.canaryd.build-cleanup"
  @obsolete_agent_labels ["com.thaddeusjiang.canaryd.thermal"]

  alias Canaryd.{Duration, NotificationHelper, Paths}

  def label, do: @label

  @doc false
  def labels, do: [@label, @build_cleanup_label]

  @doc false
  def obsolete_agent_labels, do: @obsolete_agent_labels

  @doc false
  def agent_specs(escript_path, config \\ nil) do
    config = config || Canaryd.Config.defaults()

    [
      %{
        label: @label,
        command: "check",
        interval: config.check_interval,
        run_at_load: true,
        escript_path: escript_path
      },
      %{
        label: @build_cleanup_label,
        command: "clean",
        calendar: config.cleanup_at,
        arguments:
          if(config.retention_override,
            do: [
              "--build-retention",
              Canaryd.Config.format(:build_retention, config.build_retention)
            ],
            else: []
          ),
        run_at_load: false,
        escript_path: escript_path
      }
    ]
  end

  def install(options \\ []) do
    runner = Keyword.get(options, :runner, &System.cmd/3)

    ensure_helper =
      Keyword.get(options, :ensure_notification_helper, &NotificationHelper.ensure_installed/0)

    with {:ok, config} <- resolve_config(options),
         agents = agent_specs(executable_path(), config),
         :ok <- ensure_helper.(),
         :ok <- remove_obsolete_agents(runner) do
      install_agents(agents, runner)
    end
  end

  defp resolve_config(options) do
    case Keyword.fetch(options, :config) do
      {:ok, config} -> {:ok, config}
      :error -> Canaryd.Config.resolve(options)
    end
  end

  defp install_agents(agents, runner) do
    File.mkdir_p!(Path.dirname(plist_path(@label)))
    File.mkdir_p!(log_dir())

    Enum.reduce_while(agents, :ok, fn agent, :ok ->
      case install_agent(agent, runner) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp install_agent(agent, runner) do
    path = plist_path(agent.label)
    plist = agent_plist(agent)
    loaded = loaded?(agent.label, runner)

    if File.read(path) == {:ok, plist} do
      if loaded, do: :ok, else: bootstrap(agent, runner)
    else
      with :ok <- if(loaded, do: bootout(agent.label, runner), else: :ok),
           :ok <- File.write(path, plist) do
        bootstrap(agent, runner)
      end
    end
  end

  def uninstall do
    configured_agents()
    |> Enum.map(& &1.label)
    |> Kernel.++(@obsolete_agent_labels)
    |> remove_agents(&System.cmd/3)

    NotificationHelper.remove()
    :ok
  end

  defp remove_obsolete_agents(runner) do
    remove_agents(@obsolete_agent_labels, runner)
  end

  defp remove_agents(labels, runner) do
    Enum.each(labels, fn label ->
      if loaded?(label, runner), do: bootout(label, runner)
      File.rm(plist_path(label))
    end)

    :ok
  end

  defp bootstrap(agent, runner) do
    args = ["bootstrap", "gui/#{uid()}", plist_path(agent.label)]

    case runner.("launchctl", args, stderr_to_stdout: true) do
      {_, 0} -> :ok
      {error, _status} -> {:error, error}
    end
  end

  defp bootout(label, runner) do
    case runner.("launchctl", ["bootout", "gui/#{uid()}/#{label}"], stderr_to_stdout: true) do
      {_, 0} -> :ok
      {error, _status} -> {:error, error}
    end
  end

  defp loaded?(label, runner) do
    case runner.("launchctl", ["list", label], stderr_to_stdout: true) do
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
        #{Enum.map_join(Map.get(agent, :arguments, []), "\n", &"<string>#{&1}</string>")}
      </array>
      #{schedule_plist(agent)}#{run_at_load_plist(agent)}
      <key>StandardOutPath</key>
      <string>#{log_dir()}/stdout.log</string>
      <key>StandardErrorPath</key>
      <string>#{log_dir()}/stderr.log</string>
      <key>EnvironmentVariables</key>
      <dict>
        <key>PATH</key>
        <string>#{erlang_bin()}:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
      </dict>
    </dict>
    </plist>
    """
  end

  defp schedule_plist(%{interval: interval}) do
    """
    <key>StartInterval</key>
    <integer>#{Duration.to_external(interval, :second)}</integer>
    """
  end

  defp schedule_plist(%{calendar: %{hour: hour, minute: minute}}) do
    """
    <key>StartCalendarInterval</key>
    <dict>
      <key>Hour</key>
      <integer>#{hour}</integer>
      <key>Minute</key>
      <integer>#{minute}</integer>
    </dict>
    """
  end

  defp run_at_load_plist(%{run_at_load: true}) do
    """
    <key>RunAtLoad</key>
    <true/>
    """
  end

  defp run_at_load_plist(_agent), do: ""
end
