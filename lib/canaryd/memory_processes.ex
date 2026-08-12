defmodule Canaryd.MemoryProcesses do
  @moduledoc """
  Finds memory-heavy third-party applications owned by the current user.

  Memory and CPU usage include every process whose executable lives inside the
  app bundle. System apps, utilities, active applications, nested helper apps,
  and processes without a registered main application are never actionable.
  """

  alias Canaryd.Duration

  @termination_poll Duration.milliseconds(200)

  @application_script """
  ObjC.import("AppKit")

  function text(value) {
    return value ? ObjC.unwrap(value) : ""
  }

  function encode(value) {
    return encodeURIComponent(value || "")
  }

  $.NSWorkspace.sharedWorkspace.runningApplications.js.map(function(app) {
    return [
      app.processIdentifier,
      app.activationPolicy,
      app.active ? 1 : 0,
      encode(text(app.localizedName)),
      encode(text(app.bundleIdentifier)),
      encode(app.bundleURL ? text(app.bundleURL.path) : "")
    ].join("\\t")
  }).join("\\n")
  """

  @terminate_script """
  ObjC.import("AppKit")
  var app = $.NSRunningApplication.runningApplicationWithProcessIdentifier(%PID%)
  var expectedBundleId = decodeURIComponent("%BUNDLE_ID%")
  var expectedBundlePath = decodeURIComponent("%BUNDLE_PATH%")

  if (!ObjC.unwrap(app)) {
    "stopped"
  } else {
    var bundleId = app.bundleIdentifier ? ObjC.unwrap(app.bundleIdentifier) : ""
    var bundlePath = app.bundleURL ? ObjC.unwrap(app.bundleURL.path) : ""

    if (bundleId !== expectedBundleId || bundlePath !== expectedBundlePath) {
      "changed"
    } else if (app.terminate) {
      "requested"
    } else {
      "refused"
    }
  }
  """

  @doc "Returns registered third-party apps with aggregate RSS and CPU use."
  def scan do
    with {:ok, uid} <- current_uid(),
         {:ok, application_output} <-
           cmd("osascript", ["-l", "JavaScript", "-e", @application_script]),
         {:ok, apps} <- parse_running_apps(application_output),
         {:ok, process_output} <- cmd("ps", ["-Ao", "pid=,uid=,pcpu=,rss=,command="]) do
      {:ok, parse_processes(process_output, uid, apps)}
    else
      _ -> {:error, :unavailable}
    end
  end

  @doc false
  def parse_running_apps(output) do
    output
    |> String.trim()
    |> case do
      "" -> {:ok, []}
      rows -> parse_app_rows(String.split(rows, "\n"))
    end
  end

  @doc false
  def parse_processes(output, current_uid, apps) do
    apps = Enum.filter(apps, &safe_application_path?(&1.bundle_path))

    usage =
      output
      |> String.split("\n", trim: true)
      |> Enum.flat_map(&parse_process_row/1)
      |> Enum.filter(&(&1.uid == current_uid))
      |> Enum.reduce(%{}, fn process, totals ->
        case owning_app(process.command, apps) do
          nil ->
            totals

          app ->
            Map.update(
              totals,
              app.id,
              %{rss_kb: process.rss_kb, cpu_percent: process.cpu_percent},
              fn current ->
                %{
                  rss_kb: current.rss_kb + process.rss_kb,
                  cpu_percent: current.cpu_percent + process.cpu_percent
                }
              end
            )
        end
      end)

    apps
    |> Enum.flat_map(fn app ->
      case Map.get(usage, app.id) do
        nil ->
          []

        totals ->
          [
            app
            |> Map.put(:rss_mb, Float.round(totals.rss_kb / 1024, 1))
            |> Map.put(:cpu_percent, Float.round(totals.cpu_percent, 1))
            |> Map.put(:actionable, eligible?(app))
          ]
      end
    end)
    |> Enum.sort_by(& &1.rss_mb, :desc)
  end

  @doc "Requests a graceful application termination and never escalates to SIGKILL."
  def close(%{pid: pid, bundle_id: bundle_id, bundle_path: bundle_path})
      when is_integer(pid) and pid > 0 and is_binary(bundle_id) and is_binary(bundle_path) do
    script =
      @terminate_script
      |> String.replace("%PID%", Integer.to_string(pid))
      |> String.replace("%BUNDLE_ID%", URI.encode(bundle_id))
      |> String.replace("%BUNDLE_PATH%", URI.encode(bundle_path))

    case cmd("osascript", ["-l", "JavaScript", "-e", script]) do
      {:ok, output} ->
        case String.trim(output) do
          "stopped" -> :ok
          "requested" -> wait_for_stop(pid, 10)
          "changed" -> {:error, :process_identity_changed}
          "refused" -> {:error, :termination_refused}
          _ -> {:error, :termination_failed}
        end

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    _ -> {:error, :termination_failed}
  end

  def close(_app), do: {:error, :invalid_app}

  defp parse_app_rows(rows) do
    Enum.reduce_while(rows, {:ok, []}, fn row, {:ok, apps} ->
      case parse_app_row(row) do
        {:ok, app} -> {:cont, {:ok, [app | apps]}}
        :skip -> {:cont, {:ok, apps}}
        :error -> {:halt, {:error, :invalid_output}}
      end
    end)
    |> case do
      {:ok, apps} -> {:ok, Enum.reverse(apps)}
      error -> error
    end
  end

  defp parse_app_row(row) do
    case String.split(row, "\t") do
      [pid_text, policy_text, active_text, name, bundle_id, bundle_path] ->
        with {pid, ""} when pid > 0 <- Integer.parse(pid_text),
             {activation_policy, ""} <- Integer.parse(policy_text),
             active when active in [true, false] <- parse_boolean(active_text) do
          bundle_id = URI.decode(bundle_id)
          bundle_path = URI.decode(bundle_path)
          id = if bundle_id == "", do: bundle_path, else: bundle_id

          if id == "" or bundle_path == "" do
            :skip
          else
            {:ok,
             %{
               id: id,
               name: URI.decode(name),
               pid: pid,
               activation_policy: activation_policy,
               active: active,
               bundle_id: bundle_id,
               bundle_path: bundle_path
             }}
          end
        else
          _ -> :error
        end

      _ ->
        :error
    end
  rescue
    _ -> :error
  end

  defp parse_boolean("0"), do: false
  defp parse_boolean("1"), do: true
  defp parse_boolean(_value), do: :invalid

  defp parse_process_row(row) do
    case String.split(String.trim(row), ~r/\s+/, parts: 5) do
      [pid_text, uid_text, cpu_text, rss_text, command] ->
        with {pid, ""} when pid > 0 <- Integer.parse(pid_text),
             {uid, ""} <- Integer.parse(uid_text),
             {cpu_percent, ""} <- Float.parse(cpu_text),
             {rss_kb, ""} when rss_kb >= 0 <- Integer.parse(rss_text) do
          [%{pid: pid, uid: uid, cpu_percent: cpu_percent, rss_kb: rss_kb, command: command}]
        else
          _ -> []
        end

      _ ->
        []
    end
  end

  defp owning_app(command, apps) do
    apps
    |> Enum.filter(&command_in_bundle?(command, &1.bundle_path))
    |> Enum.max_by(&String.length(&1.bundle_path), fn -> nil end)
  end

  defp command_in_bundle?(command, bundle_path) do
    is_binary(bundle_path) and bundle_path != "" and
      (command == bundle_path or String.starts_with?(command, bundle_path <> "/"))
  end

  defp eligible?(%{active: false, bundle_id: bundle_id, bundle_path: bundle_path}) do
    third_party_bundle?(bundle_id) and safe_application_path?(bundle_path)
  end

  defp eligible?(_app), do: false

  defp third_party_bundle?(bundle_id) do
    is_binary(bundle_id) and bundle_id != "" and
      not String.starts_with?(String.downcase(bundle_id), "com.apple.")
  end

  defp safe_application_path?(path) when is_binary(path) do
    Regex.match?(~r{^/Applications/[^/]+\.app$}, path) or
      Regex.match?(~r{^/Users/[^/]+/Applications/[^/]+\.app$}, path)
  end

  defp safe_application_path?(_path), do: false

  defp current_uid do
    with {:ok, output} <- cmd("id", ["-u"]),
         {uid, ""} <- Integer.parse(String.trim(output)) do
      {:ok, uid}
    else
      _ -> {:error, :unavailable}
    end
  end

  defp wait_for_stop(_pid, 0), do: {:error, :process_did_not_stop}

  defp wait_for_stop(pid, attempts) do
    if process_alive?(pid) do
      Process.sleep(@termination_poll)
      wait_for_stop(pid, attempts - 1)
    else
      :ok
    end
  end

  defp process_alive?(pid) do
    case System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true) do
      {_output, 0} -> true
      _ -> false
    end
  end

  defp cmd(bin, args) do
    case System.cmd(bin, args, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, _status} -> {:error, String.trim(output)}
    end
  rescue
    _ -> {:error, :unavailable}
  end
end
