defmodule Canaryd.Apps.Unresponsive do
  @moduledoc """
  Reads the macOS WindowServer unresponsive state for supported GUI processes.

  macOS has no public API for the state shown in Force Quit. The JXA script
  resolves the private symbols at runtime. A missing symbol makes the scan
  unavailable and does not trigger any process action.
  """

  alias Canaryd.Duration

  @termination_grace Duration.milliseconds(200)
  @cursor_ui_service "com.apple.TextInputUI.xpc.CursorUIViewService"
  @cursor_ui_path "/System/Library/PrivateFrameworks/TextInputUIMacHelper.framework/Versions/A/XPCServices/CursorUIViewService.xpc"

  @scan_script """
  ObjC.import("AppKit")
  ObjC.import("ApplicationServices")
  ObjC.bindFunction("CGSMainConnectionID", ["unsigned int", []])
  ObjC.bindFunction("GetProcessForPID", ["int", ["int", "void *"]])
  ObjC.bindFunction("CGSEventIsAppUnresponsive", ["bool", ["unsigned int", "void *"]])

  function text(value) {
    return value ? ObjC.unwrap(value) : ""
  }

  function encode(value) {
    return encodeURIComponent(value || "")
  }

  var connection = $.CGSMainConnectionID()
  var rows = []

  $.NSWorkspace.sharedWorkspace.runningApplications.js.forEach(function(app) {
    var processSerialNumber = $.NSMutableData.dataWithLength(16)
    var pointer = processSerialNumber.mutableBytes

    if ($.GetProcessForPID(app.processIdentifier, pointer) == 0 &&
        $.CGSEventIsAppUnresponsive(connection, pointer)) {
      rows.push([
        app.processIdentifier,
        app.activationPolicy,
        encode(text(app.localizedName)),
        encode(text(app.bundleIdentifier)),
        encode(app.bundleURL ? text(app.bundleURL.path) : "")
      ].join("\\t"))
    }
  })

  rows.join("\\n")
  """

  @doc "Returns supported GUI apps and services that macOS marks as unresponsive."
  def scan do
    case System.cmd("osascript", ["-l", "JavaScript", "-e", @scan_script], stderr_to_stdout: true) do
      {output, 0} ->
        with {:ok, apps} <- parse_scan(output) do
          eligible_apps =
            apps
            |> Enum.filter(&eligible?/1)
            |> Enum.map(&Map.put(&1, :recovery, recovery_mode(&1)))

          {:ok, eligible_apps}
        end

      {_output, _status} ->
        {:error, :unavailable}
    end
  rescue
    _ -> {:error, :unavailable}
  end

  @doc false
  def parse_scan(output) when is_binary(output) do
    output
    |> String.trim()
    |> case do
      "" -> {:ok, []}
      rows -> parse_rows(String.split(rows, "\n"))
    end
  end

  @doc false
  def eligible?(app) do
    cursor_ui_service?(app) or regular_third_party_app?(app)
  end

  @doc false
  def recovery_mode(_app), do: :automatic

  @doc false
  def silent_recovery?(app), do: cursor_ui_service?(app)

  @doc "Stops the unresponsive process and starts or waits for its replacement."
  def restart(app) do
    restart(app, &run_command/2, &Process.sleep/1)
  end

  @doc false
  def restart(
        %{
          recovery: :automatic,
          activation_policy: 2,
          bundle_id: @cursor_ui_service,
          bundle_path: @cursor_ui_path,
          name: name,
          pid: pid
        },
        runner,
        sleeper
      )
      when is_integer(pid) and pid > 0 and is_function(runner, 2) and is_function(sleeper, 1) do
    with :ok <- stop_process(pid, runner, sleeper),
         :ok <- kickstart_cursor_ui_service(runner),
         {:ok, _new_pid} <- wait_for_replacement(name, pid, 25, runner, sleeper) do
      :ok
    end
  end

  def restart(%{pid: pid, bundle_path: bundle_path}, runner, sleeper)
      when is_integer(pid) and pid > 0 and is_binary(bundle_path) and is_function(runner, 2) and
             is_function(sleeper, 1) do
    with true <- valid_app_bundle_path?(bundle_path),
         :ok <- stop_process(pid, runner, sleeper),
         {_output, 0} <- runner.("open", ["-g", bundle_path]) do
      :ok
    else
      false -> {:error, :invalid_bundle_path}
      {:error, reason} -> {:error, reason}
      {output, status} -> {:error, {:open_failed, status, String.trim(output)}}
    end
  rescue
    _ -> {:error, :restart_failed}
  end

  def restart(_app, _runner, _sleeper), do: {:error, :invalid_app}

  @doc "Stops the current process without opening a replacement app."
  def close(%{pid: pid}) when is_integer(pid) and pid > 0 do
    stop_process(pid, &run_command/2, &Process.sleep/1)
  end

  def close(_app), do: {:error, :invalid_app}

  @doc false
  def replacement_pid(output, old_pid) do
    output
    |> String.split()
    |> Enum.find_value(fn value ->
      case Integer.parse(value) do
        {pid, ""} when pid > 0 and pid != old_pid -> pid
        _ -> nil
      end
    end)
  end

  defp parse_rows(rows) do
    Enum.reduce_while(rows, {:ok, []}, fn row, {:ok, apps} ->
      case parse_row(row) do
        {:ok, app} -> {:cont, {:ok, [app | apps]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, apps} -> {:ok, Enum.reverse(apps)}
      error -> error
    end
  end

  defp parse_row(row) do
    case String.split(row, "\t") do
      [pid, activation_policy, name, bundle_id, bundle_path] ->
        build_app(pid, activation_policy, name, bundle_id, bundle_path)

      _fields ->
        {:error, {:invalid_scan_row, row}}
    end
  end

  defp build_app(pid_text, activation_policy_text, name, bundle_id, bundle_path) do
    with {pid, ""} when pid > 0 <- Integer.parse(pid_text),
         {activation_policy, ""} <- Integer.parse(activation_policy_text) do
      name = URI.decode(name)
      bundle_id = URI.decode(bundle_id)
      bundle_path = URI.decode(bundle_path)
      id = if bundle_id == "", do: bundle_path, else: bundle_id

      if id == "" do
        invalid_scan_row(pid_text, activation_policy_text, name, bundle_id, bundle_path)
      else
        {:ok,
         %{
           id: id,
           name: name,
           pid: pid,
           activation_policy: activation_policy,
           bundle_id: bundle_id,
           bundle_path: bundle_path
         }}
      end
    else
      _ -> invalid_scan_row(pid_text, activation_policy_text, name, bundle_id, bundle_path)
    end
  rescue
    _ -> invalid_scan_row(pid_text, activation_policy_text, name, bundle_id, bundle_path)
  end

  defp invalid_scan_row(pid, activation_policy, name, bundle_id, bundle_path) do
    row = Enum.join([pid, activation_policy, name, bundle_id, bundle_path], "\t")
    {:error, {:invalid_scan_row, row}}
  end

  defp valid_app_bundle_path?(path) do
    is_binary(path) and String.starts_with?(path, "/") and String.ends_with?(path, ".app")
  end

  defp regular_third_party_app?(%{
         activation_policy: 0,
         bundle_id: bundle_id,
         bundle_path: bundle_path
       })
       when is_binary(bundle_id) and is_binary(bundle_path) do
    valid_app_bundle_path?(bundle_path) and
      not String.starts_with?(String.downcase(bundle_id), "com.apple.") and
      not String.starts_with?(bundle_path, "/System/")
  end

  defp regular_third_party_app?(_app), do: false

  defp cursor_ui_service?(%{
         activation_policy: 2,
         bundle_id: @cursor_ui_service,
         bundle_path: @cursor_ui_path
       }),
       do: true

  defp cursor_ui_service?(_app), do: false

  defp stop_process(pid, runner, sleeper) do
    case runner.("kill", ["-TERM", Integer.to_string(pid)]) do
      {_output, 0} ->
        wait_for_stop(pid, 10, runner, sleeper)

      {output, status} ->
        if process_alive?(pid, runner) do
          {:error, {:term_failed, status, String.trim(output)}}
        else
          :ok
        end
    end
  end

  defp wait_for_stop(pid, 0, runner, sleeper) do
    case runner.("kill", ["-KILL", Integer.to_string(pid)]) do
      {_output, 0} ->
        wait_after_kill(pid, 10, runner, sleeper)

      {output, status} ->
        if process_alive?(pid, runner) do
          {:error, {:kill_failed, status, String.trim(output)}}
        else
          :ok
        end
    end
  end

  defp wait_for_stop(pid, attempts, runner, sleeper) do
    if process_alive?(pid, runner) do
      sleeper.(@termination_grace)
      wait_for_stop(pid, attempts - 1, runner, sleeper)
    else
      :ok
    end
  end

  defp process_alive?(pid, runner) do
    case runner.("kill", ["-0", Integer.to_string(pid)]) do
      {_output, 0} -> true
      _ -> false
    end
  end

  defp wait_after_kill(_pid, 0, _runner, _sleeper), do: {:error, :process_did_not_stop}

  defp wait_after_kill(pid, attempts, runner, sleeper) do
    if process_alive?(pid, runner) do
      sleeper.(@termination_grace)
      wait_after_kill(pid, attempts - 1, runner, sleeper)
    else
      :ok
    end
  end

  defp kickstart_cursor_ui_service(runner) do
    with {:ok, uid} <- current_uid(runner),
         target = "user/#{uid}/#{@cursor_ui_service}",
         {_output, 0} <- runner.("launchctl", ["kickstart", target]) do
      :ok
    else
      {:error, reason} -> {:error, reason}
      {output, status} -> {:error, {:kickstart_failed, status, String.trim(output)}}
    end
  end

  defp current_uid(runner) do
    case runner.("id", ["-u"]) do
      {output, 0} ->
        case Integer.parse(String.trim(output)) do
          {uid, ""} when uid >= 0 -> {:ok, uid}
          _ -> {:error, :invalid_uid}
        end

      {output, status} ->
        {:error, {:uid_lookup_failed, status, String.trim(output)}}
    end
  end

  defp wait_for_replacement(_name, _old_pid, 0, _runner, _sleeper),
    do: {:error, :replacement_not_started}

  defp wait_for_replacement(name, old_pid, attempts, runner, sleeper) do
    case runner.("pgrep", ["-x", name]) do
      {output, _status} ->
        case replacement_pid(output, old_pid) do
          nil ->
            sleeper.(@termination_grace)
            wait_for_replacement(name, old_pid, attempts - 1, runner, sleeper)

          new_pid ->
            {:ok, new_pid}
        end
    end
  end

  defp run_command(command, args) do
    System.cmd(command, args, stderr_to_stdout: true)
  end
end
