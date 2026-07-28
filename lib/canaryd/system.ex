defmodule Canaryd.System do
  @moduledoc """
  L1 system-level health: thermal throttling, load, memory pressure,
  and user idle detection (keyboard/mouse via IOHIDSystem HIDIdleTime).
  """

  @load_factor_warn 0.8
  @chip_temperature_warn_c 70.0
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
    temperature_sample = Canaryd.Temperature.sample()
    load_pressure = load1 / cores > @load_factor_warn

    {chip_temperatures, temperature_error} =
      case temperature_sample do
        {:ok, temperatures} -> {temperatures, nil}
        {:error, reason} -> {%{cpu_temperature_c: nil, gpu_temperature_c: nil}, reason}
      end

    chip_temperature_pressure = chip_temperature_pressure?(chip_temperatures)
    warnings = []
    warnings = if throttled, do: ["CPU thermal throttling active" | warnings], else: warnings

    warnings = chip_temperature_warnings(warnings, chip_temperatures)

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
      cpu_temperature_c: chip_temperatures.cpu_temperature_c,
      gpu_temperature_c: chip_temperatures.gpu_temperature_c,
      temperature_source: if(is_nil(temperature_error), do: :macmon, else: :unavailable),
      temperature_error: temperature_error,
      thermal_pressure: throttled or chip_temperature_pressure or load_pressure,
      mem_free_pct: mem_free,
      warnings: warnings,
      hot_processes:
        if(throttled or chip_temperature_pressure or load_pressure, do: hot_processes(), else: [])
    }
  end

  @doc false
  def chip_temperature_pressure?(temperatures) do
    above_threshold?(temperatures.cpu_temperature_c) or
      above_threshold?(temperatures.gpu_temperature_c)
  end

  @doc "Formats chip sensor and battery temperatures without mixing their meaning."
  def temperature_summary(%{temperature_source: :macmon} = system) do
    [
      "CPU #{format_celsius(system.cpu_temperature_c)}",
      "GPU #{format_celsius(system.gpu_temperature_c)}",
      battery_temperature_summary(system.battery_temperature_c)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("; ")
  end

  def temperature_summary(system) do
    ["CPU/GPU temperature unavailable", battery_temperature_summary(system.battery_temperature_c)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("; ")
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

  defp chip_temperature_warnings(warnings, temperatures) do
    warnings =
      if above_threshold?(temperatures.cpu_temperature_c),
        do: ["CPU temperature #{format_celsius(temperatures.cpu_temperature_c)}" | warnings],
        else: warnings

    if above_threshold?(temperatures.gpu_temperature_c),
      do: ["GPU temperature #{format_celsius(temperatures.gpu_temperature_c)}" | warnings],
      else: warnings
  end

  defp above_threshold?(value) do
    is_number(value) and value >= @chip_temperature_warn_c
  end

  defp format_celsius(value), do: "#{value}°C"

  defp battery_temperature_summary(value) when is_number(value) do
    "battery #{format_celsius(value)}"
  end

  defp battery_temperature_summary(_value), do: nil

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
