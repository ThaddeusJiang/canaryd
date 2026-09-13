defmodule Canaryd.System do
  @moduledoc """
  L1 system-level health: thermal throttling, load, memory pressure,
  and user idle detection (keyboard/mouse via IOHIDSystem HIDIdleTime).
  """

  @load_factor_warn 0.8
  @chip_temperature_warn_c 70.0
  @hot_process_cpu_min 20.0

  alias Canaryd.Duration

  @doc "Milliseconds since the last keyboard or mouse input."
  def idle_duration do
    case cmd("ioreg", ["-c", "IOHIDSystem", "-d", "1"]) do
      {:ok, out} ->
        parse_idle_duration(out)

      _ ->
        0
    end
  end

  @doc false
  def parse_idle_duration(output) do
    case Regex.run(~r/"HIDIdleTime" = (\d+)/, output) do
      [_, nanoseconds] ->
        nanoseconds
        |> String.to_integer()
        |> Duration.from_external(:nanosecond)

      _ ->
        0
    end
  end

  @doc """
  Returns %{load_per_core, load1, cores, throttled, mem_free_pct, warnings: [...]}.
  """
  def check(options \\ []) do
    runner = Keyword.get(options, :runner, &cmd/2)

    temperature_sampler =
      Keyword.get(options, :temperature_sampler, &Canaryd.Temperature.sample/0)

    {load1, cores} = load(runner)
    load_per_core = if is_number(load1) and is_integer(cores), do: load1 / cores
    throttled = thermal_throttled?(runner)
    mem_free = memory_free_pct(runner)
    battery_temperature = battery_temperature(runner)
    temperature_sample = temperature_sampler.()
    load_pressure = is_number(load_per_core) and load_per_core > @load_factor_warn

    {chip_temperatures, temperature_error} =
      case temperature_sample do
        {:ok, temperatures} -> {temperatures, nil}
        {:error, reason} -> {%{cpu_temperature_c: nil, gpu_temperature_c: nil}, reason}
      end

    chip_temperature_pressure = chip_temperature_pressure?(chip_temperatures)
    thermal_pressure = throttled == true or chip_temperature_pressure or load_pressure

    sampling_warnings =
      [
        {is_nil(load_per_core), "system load unavailable"},
        {is_nil(throttled), "thermal throttling unavailable"},
        {not is_nil(temperature_error), "CPU/GPU temperature unavailable"}
      ]
      |> Enum.filter(fn {unavailable, _message} -> unavailable end)
      |> Enum.map(&elem(&1, 1))

    thermal_status =
      cond do
        thermal_pressure -> :high
        sampling_warnings != [] -> :unavailable
        true -> :normal
      end

    warnings = sampling_warnings
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
      load_per_core: if(is_number(load_per_core), do: Float.round(load_per_core, 3)),
      throttled: throttled,
      battery_temperature_c: battery_temperature,
      cpu_temperature_c: chip_temperatures.cpu_temperature_c,
      gpu_temperature_c: chip_temperatures.gpu_temperature_c,
      temperature_source: if(is_nil(temperature_error), do: :macmon, else: :unavailable),
      temperature_error: temperature_error,
      thermal_pressure: thermal_pressure,
      thermal_status: thermal_status,
      mem_free_pct: mem_free,
      warnings: warnings,
      hot_processes: if(thermal_pressure, do: hot_processes(runner), else: [])
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

  defp load(runner) do
    with {:ok, cpu_output} <- runner.("sysctl", ["-n", "hw.ncpu"]),
         {cores, ""} when cores > 0 <- Integer.parse(String.trim(cpu_output)),
         {:ok, load_output} <- runner.("sysctl", ["-n", "vm.loadavg"]),
         [_, first, _second, _third] <-
           Regex.run(
             ~r/^\s*\{\s*(\d+(?:\.\d+)?)\s+(\d+(?:\.\d+)?)\s+(\d+(?:\.\d+)?)\s*\}\s*$/,
             load_output
           ),
         {load1, ""} <- Float.parse(first) do
      {load1, cores}
    else
      _ -> {nil, nil}
    end
  end

  defp thermal_throttled?(runner) do
    case runner.("pmset", ["-g", "therm"]) do
      {:ok, out} ->
        case Regex.run(~r/CPU_Speed_Limit\s*=\s*(\d+)/, out) do
          [_, pct] -> String.to_integer(pct) < 100
          _ -> if String.contains?(out, "No CPU power status has been recorded"), do: false
        end

      _ ->
        nil
    end
  end

  defp memory_free_pct(runner) do
    case runner.("memory_pressure", []) do
      {:ok, out} ->
        case Regex.run(~r/free percentage:\s*(\d+)%/, out) do
          [_, pct] -> String.to_integer(pct)
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp battery_temperature(runner) do
    case runner.("ioreg", ["-r", "-n", "AppleSmartBattery"]) do
      {:ok, out} -> parse_battery_temperature(out)
      _ -> nil
    end
  end

  defp hot_processes(runner) do
    with {:ok, uid_output} <- runner.("id", ["-u"]),
         {uid, ""} <- Integer.parse(String.trim(uid_output)),
         {:ok, output} <- runner.("ps", ["-Ao", "pid=,uid=,pcpu=,command="]) do
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
