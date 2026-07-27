defmodule Canaryd.System do
  @moduledoc """
  L1 system-level health: thermal throttling, load, memory pressure,
  and user idle detection (keyboard/mouse via IOHIDSystem HIDIdleTime).
  """

  @load_factor_warn 0.8
  @battery_temperature_warn_c 40.0
  @hot_process_cpu_min 20.0

  @doc "Seconds since last keyboard/mouse input."
  def idle_seconds do
    case cmd("ioreg", ["-c", "IOHIDSystem", "-d", "1"]) do
      {:ok, out} ->
        case Regex.run(~r/"HIDIdleTime" = (\d+)/, out) do
          [_, ns] -> div(String.to_integer(ns), 1_000_000_000)
          _ -> 0
        end

      _ ->
        0
    end
  end

  @doc """
  Returns %{load_per_core, load1, cores, throttled, mem_free_pct, warnings: [...]}.
  """
  def check do
    {load1, cores} = load()
    throttled = thermal_throttled?()
    mem_free = memory_free_pct()
    battery_temperature = battery_temperature()
    load_pressure = load1 / cores > @load_factor_warn

    temperature_pressure =
      is_number(battery_temperature) and battery_temperature >= @battery_temperature_warn_c

    warnings = []
    warnings = if throttled, do: ["CPU thermal throttling active" | warnings], else: warnings

    warnings =
      if temperature_pressure,
        do: ["battery temperature #{battery_temperature} C" | warnings],
        else: warnings

    warnings =
      if load_pressure,
        do: [
          "load1 #{Float.round(load1, 2)} >= #{Float.round(cores * @load_factor_warn, 1)} (#{cores} cores)"
          | warnings
        ],
        else: warnings

    warnings =
      if is_number(mem_free) and mem_free < 10,
        do: ["memory free #{mem_free}%" | warnings],
        else: warnings

    %{
      load1: load1,
      cores: cores,
      load_per_core: Float.round(load1 / cores, 3),
      throttled: throttled,
      battery_temperature_c: battery_temperature,
      thermal_pressure: throttled or temperature_pressure or load_pressure,
      mem_free_pct: mem_free,
      warnings: warnings,
      hot_processes:
        if(throttled or temperature_pressure or load_pressure, do: hot_processes(), else: [])
    }
  end

  @doc false
  def parse_battery_temperature(output) do
    case Regex.run(~r/"Temperature"\s*=\s*(\d+)/, output) do
      [_, value] ->
        value
        |> String.to_integer()
        |> Kernel./(10)
        |> Kernel.-(273.15)
        |> Float.round(1)

      _ ->
        nil
    end
  end

  @doc false
  def parse_hot_processes(output, current_uid) do
    output
    |> String.split("\n", trim: true)
    |> Enum.flat_map(&parse_process_row(&1, current_uid))
    |> Enum.filter(&(&1.cpu_percent >= @hot_process_cpu_min))
    |> Enum.sort_by(& &1.cpu_percent, :desc)
    |> Enum.take(5)
  end

  defp load do
    cores =
      case cmd("sysctl", ["-n", "hw.ncpu"]) do
        {:ok, out} -> String.trim(out) |> String.to_integer()
        _ -> 1
      end

    load1 =
      case cmd("sysctl", ["-n", "vm.loadavg"]) do
        {:ok, out} ->
          case Regex.run(~r/([\d.]+)/, out) do
            [_, l1] -> String.to_float(l1)
            _ -> 0.0
          end

        _ ->
          0.0
      end

    {load1, cores}
  end

  defp thermal_throttled? do
    case cmd("pmset", ["-g", "therm"]) do
      {:ok, out} ->
        case Regex.run(~r/CPU_Speed_Limit\s*=\s*(\d+)/, out) do
          [_, pct] -> String.to_integer(pct) < 100
          _ -> false
        end

      _ ->
        false
    end
  end

  defp memory_free_pct do
    case cmd("memory_pressure", []) do
      {:ok, out} ->
        case Regex.run(~r/free percentage:\s*(\d+)%/, out) do
          [_, pct] -> String.to_integer(pct)
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp battery_temperature do
    case cmd("ioreg", ["-r", "-n", "AppleSmartBattery"]) do
      {:ok, out} -> parse_battery_temperature(out)
      _ -> nil
    end
  end

  defp hot_processes do
    with {:ok, uid_output} <- cmd("id", ["-u"]),
         {uid, ""} <- Integer.parse(String.trim(uid_output)),
         {:ok, output} <- cmd("ps", ["-Ao", "pid=,uid=,pcpu=,command="]) do
      own_pid = Elixir.System.pid() |> String.to_integer()
      Enum.reject(parse_hot_processes(output, uid), &(&1.pid == own_pid))
    else
      _ -> []
    end
  end

  defp parse_process_row(row, current_uid) do
    case String.split(String.trim(row), ~r/\s+/, parts: 4) do
      [pid_text, uid_text, cpu_text, command] ->
        with {pid, ""} when pid > 0 <- Integer.parse(pid_text),
             {uid, ""} <- Integer.parse(uid_text),
             {cpu, ""} <- Float.parse(cpu_text) do
          bundle_path = app_bundle_path(command)
          name = process_name(command, bundle_path)

          [
            %{
              id: bundle_path || "#{name}:#{pid}",
              name: name,
              pid: pid,
              cpu_percent: cpu,
              bundle_path: bundle_path,
              actionable:
                uid == current_uid and safe_third_party_app?(bundle_path) and
                  direct_app_process?(command, bundle_path)
            }
          ]
        else
          _ -> []
        end

      _ ->
        []
    end
  end

  defp app_bundle_path(command) do
    case Regex.run(~r{(/Applications/[^/\n]+\.app)(?:/|\s|$)}, command) do
      [_, path] -> path
      _ -> nil
    end
  end

  defp process_name(_command, bundle_path) when is_binary(bundle_path) do
    bundle_path |> Path.basename(".app")
  end

  defp process_name(command, nil) do
    command
    |> String.split(~r/\s+/, parts: 2)
    |> hd()
    |> Path.basename()
  end

  defp safe_third_party_app?(path) when is_binary(path) do
    String.starts_with?(path, "/Applications/") and
      not String.starts_with?(path, "/Applications/Utilities/")
  end

  defp safe_third_party_app?(_path), do: false

  defp direct_app_process?(command, bundle_path) when is_binary(bundle_path) do
    executable_prefix = bundle_path <> "/Contents/MacOS/"
    remainder = String.replace_prefix(command, executable_prefix, "")

    remainder != command and not String.contains?(remainder, ".app/")
  end

  defp direct_app_process?(_command, _bundle_path), do: false

  defp cmd(bin, args) do
    case System.cmd(bin, args, stderr_to_stdout: true) do
      {out, 0} -> {:ok, out}
      {out, _} -> {:error, out}
    end
  rescue
    _ -> {:error, :unavailable}
  end
end
