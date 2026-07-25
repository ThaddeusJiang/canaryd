defmodule Canaryd.System do
  @moduledoc """
  L1 system-level health: thermal throttling, load, memory pressure,
  and user idle detection (keyboard/mouse via IOHIDSystem HIDIdleTime).
  """

  @load_factor_warn 0.8

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

    warnings = []
    warnings = if throttled, do: ["CPU thermal throttling active" | warnings], else: warnings

    warnings =
      if load1 / cores > @load_factor_warn,
        do: ["load1 #{Float.round(load1, 2)} >= #{Float.round(cores * @load_factor_warn, 1)} (#{cores} cores)" | warnings],
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
      mem_free_pct: mem_free,
      warnings: warnings
    }
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

  defp cmd(bin, args) do
    case System.cmd(bin, args, stderr_to_stdout: true) do
      {out, 0} -> {:ok, out}
      {out, _} -> {:error, out}
    end
  rescue
    _ -> {:error, :unavailable}
  end
end
