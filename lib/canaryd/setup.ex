defmodule Canaryd.Setup do
  @moduledoc """
  Self-installing launchd agent. launchd is an implementation detail:
  users never touch plist files. Every CLI invocation ensures the agent
  is present and loaded; if the user deletes it, the next run heals it.
  """

  @label "com.thaddeusjiang.canaryd"
  @interval_sec 300

  def label, do: @label

  @doc "Idempotent. Safe to call on every CLI run."
  def ensure_installed do
    cond do
      not File.exists?(plist_path()) ->
        install()

      not loaded?() ->
        bootstrap()

      true ->
        :ok
    end
  end

  def install do
    File.mkdir_p!(Path.dirname(plist_path()))
    File.mkdir_p!(log_dir())
    File.write!(plist_path(), plist())
    bootstrap()
  end

  def uninstall do
    if loaded?(), do: bootout()
    File.rm(plist_path())
    :ok
  end

  defp bootstrap do
    bootout()

    case System.cmd("launchctl", ["bootstrap", "gui/#{uid()}", plist_path()],
           stderr_to_stdout: true
         ) do
      {_, 0} -> :ok
      {err, _} -> {:error, err}
    end
  end

  defp bootout do
    System.cmd("launchctl", ["bootout", "gui/#{uid()}/#{@label}"], stderr_to_stdout: true)
    :ok
  end

  defp loaded? do
    case System.cmd("launchctl", ["list", @label], stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  end

  defp uid do
    {out, 0} = System.cmd("id", ["-u"], stderr_to_stdout: true)
    String.trim(out)
  end

  defp plist_path do
    Path.expand("~/Library/LaunchAgents/#{@label}.plist")
  end

  defp log_dir, do: Canaryd.Store.dir()

  # Absolute path of the currently running escript, e.g. ~/.mix/escripts/canaryd
  defp escript_path do
    case :escript.script_name() do
      ~c"" -> Path.expand("canaryd")
      name -> Path.expand(List.to_string(name))
    end
  end

  # escript shebang is `#!/usr/bin/env escript`, so erlang's bin must be on PATH
  defp erlang_bin do
    Path.join([:code.root_dir(), "bin"])
  end

  defp plist do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
      <key>Label</key>
      <string>#{@label}</string>
      <key>ProgramArguments</key>
      <array>
        <string>#{escript_path()}</string>
        <string>check</string>
      </array>
      <key>StartInterval</key>
      <integer>#{@interval_sec}</integer>
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
