defmodule Canaryd.CLI do
  @moduledoc "escript entry for checks, status, target history, setup, and version output."

  alias Canaryd.{
    BuildCleanup,
    Checker,
    Duration,
    MemoryMonitor,
    SimulatorMonitor,
    Setup,
    Store,
    System,
    ThermalMonitor,
    UnresponsiveMonitor
  }

  alias Canaryd.Apps.CleanClip

  def main(argv, options \\ []) do
    # launchd is an implementation detail: self-heal on every invocation
    unless argv in [["--version"], ["version"], ["uninstall"]] do
      ensure_installed = Keyword.get(options, :ensure_installed, &Setup.ensure_installed/0)
      ensure_installed.()
    end

    build_cleanup = Keyword.get(options, :build_cleanup, &BuildCleanup.run/0)
    dispatch(argv, build_cleanup)
  end

  defp dispatch(["clean"], build_cleanup) do
    case build_cleanup.() do
      {:ok, result} ->
        record_build_cleanup(result)
        print_build_cleanup(result)

      {:error, :locked} ->
        IO.puts("another build cleanup is running, skipping")

      {:error, reason} ->
        IO.puts("build cleanup failed: #{inspect(reason)}")
    end
  end

  defp dispatch(argv, _build_cleanup), do: dispatch(argv)

  defp dispatch([command]) when command in ["--version", "version"] do
    IO.puts("canaryd #{Application.spec(:canaryd, :vsn)}")
  end

  defp dispatch(["check"]) do
    case Checker.run() do
      {:error, :locked} ->
        IO.puts("another check is running, skipping")

      {:skipped_idle, idle, sys, apps} ->
        IO.puts(
          "idle #{Duration.to_external(idle, :second)}s, CleanClip probe skipped; " <>
            "system warnings: #{length(sys.warnings)}; " <>
            "#{thermal_summary(sys)}; #{memory_summary(sys)}; " <>
            "#{simulator_summary(sys)}; #{app_check_summary(apps)}"
        )

      {:checked, _idle, sys, cc, apps} ->
        IO.puts(
          "cleanclip: #{cc.probe} (#{cc.action}), failures=#{cc.failures}; " <>
            "system warnings: #{inspect(sys.warnings)}; #{thermal_summary(sys)}; " <>
            "#{memory_summary(sys)}; #{simulator_summary(sys)}"
        )

        IO.puts(app_check_summary(apps))
    end
  end

  defp dispatch(["thermal-check"]) do
    case Checker.run_thermal() do
      {:error, :locked} ->
        IO.puts("another check is running, skipping")

      {:thermal_checked, system} ->
        IO.puts(thermal_summary(system))
    end
  end

  defp dispatch(["status"]) do
    idle = System.idle_duration()
    current_system = System.check()

    Store.with_tables(fn state, events ->
      for target <- [:cleanclip, :system] do
        s = Store.get_state(state, target)

        IO.puts(
          "#{target}: #{s.status} | last_probe=#{s.last_probe} failures=#{s.consecutive_failures} " <>
            "| last_restart=#{fmt(s.last_restart_at)} | updated=#{fmt(s.updated_at)}"
        )
      end

      recent = Store.list_events(events, nil, 5)
      IO.puts("\nrecent events:")
      Enum.each(recent, &IO.puts("  #{fmt(&1.at)}  #{&1.target}  #{&1.type}"))

      monitor_state =
        Store.get_value(state, :unresponsive_apps, UnresponsiveMonitor.default_state())

      pending_apps = UnresponsiveMonitor.pending_apps(monitor_state)
      IO.puts("\nunresponsive apps: #{format_pending_apps(pending_apps)}")

      thermal_state =
        Store.get_value(state, :thermal_processes, ThermalMonitor.default_state())

      IO.puts("thermal suspects pending: #{map_size(thermal_state.observations)}")

      memory_state =
        Store.get_value(state, :idle_memory_processes, MemoryMonitor.default_state())

      pending_memory_apps = MemoryMonitor.pending_apps(memory_state)
      IO.puts("idle high-memory apps: #{format_memory_apps(pending_memory_apps)}")

      simulator_state =
        Store.get_value(state, :idle_simulators, SimulatorMonitor.default_state())

      pending_simulators = SimulatorMonitor.pending_devices(simulator_state)
      IO.puts("idle Simulators pending: #{format_simulators(pending_simulators)}")
    end)

    IO.puts("\ncleanclip process alive: #{CleanClip.process_alive?()}")
    IO.puts("user idle: #{Duration.to_external(idle, :second)}s")
    IO.puts(thermal_summary(current_system))
  end

  defp dispatch(["history"]), do: dispatch(["history", "cleanclip"])

  defp dispatch(["history", target]) do
    Store.with_tables(fn _state, events ->
      events
      |> Store.list_events(history_target(target), 50)
      |> Enum.each(fn e ->
        details = Map.drop(e, [:target, :type, :at])

        IO.puts(
          "#{fmt(e.at)}  #{e.type}#{if map_size(details) > 0, do: "  #{inspect(details)}", else: ""}"
        )
      end)
    end)
  end

  defp dispatch(["install"]) do
    case Setup.install() do
      :ok ->
        IO.puts("launchd agents installed (#{Enum.join(Setup.labels(), ", ")})")

      {:error, err} ->
        IO.puts("install failed: #{err}")
    end
  end

  defp dispatch(["uninstall"]) do
    Setup.uninstall()
    IO.puts("launchd agents removed")
  end

  defp dispatch(_argv) do
    IO.puts("""
    canaryd - Mac health monitor

    usage:
      canaryd check              run one check round (launchd does this every 5 min)
      canaryd thermal-check      run one thermal check now
      canaryd status             current health snapshot
      canaryd clean              remove stale Xcode and Cargo build artifacts
      canaryd history [target]   event timeline (cleanclip, system, thermal, memory, simulators, builds, apps)
      canaryd install            (re)install the launchd agents (usually automatic)
      canaryd uninstall          remove the launchd agents
      canaryd --version          show the installed version
    """)
  end

  defp app_check_summary(%{status: :available, detected: detected, actions: actions}) do
    "unresponsive apps=#{detected}, actions=#{inspect(actions)}"
  end

  defp app_check_summary(%{status: :unavailable}) do
    "unresponsive app scan unavailable"
  end

  defp format_pending_apps([]), do: "none"

  defp format_pending_apps(apps) do
    Enum.map_join(apps, ", ", fn app -> "#{app.name} (PID #{app.pid})" end)
  end

  defp format_memory_apps([]), do: "none"

  defp format_memory_apps(apps) do
    Enum.map_join(apps, ", ", fn app ->
      "#{app.name} (PID #{app.pid}, RSS #{app.rss_mb} MB)"
    end)
  end

  defp format_simulators([]), do: "none"

  defp format_simulators(devices) do
    Enum.map_join(devices, ", ", fn device -> "#{device.name} (#{device.udid})" end)
  end

  defp memory_summary(%{memory_monitor: %{status: :skipped_active}}) do
    "idle memory scan: waiting for 30 minutes of user inactivity"
  end

  defp memory_summary(%{memory_monitor: %{status: :available} = monitor}) do
    "idle high-memory apps=#{monitor.detected}, actions=#{inspect(monitor.actions)}"
  end

  defp memory_summary(%{memory_monitor: %{status: :unavailable}}) do
    "idle memory scan unavailable"
  end

  defp simulator_summary(%{simulator_monitor: %{status: :skipped_active}}) do
    "idle Simulator scan: waiting for 30 minutes of user inactivity"
  end

  defp simulator_summary(%{simulator_monitor: %{status: :skipped_automation} = monitor}) do
    names = Enum.map_join(monitor.automation_processes, ", ", & &1.name)
    "idle Simulator scan: automation active (#{names})"
  end

  defp simulator_summary(%{simulator_monitor: %{status: :available} = monitor}) do
    "booted Simulators=#{monitor.booted}, idle candidates=#{monitor.detected}, " <>
      "actions=#{inspect(monitor.actions)}"
  end

  defp simulator_summary(%{simulator_monitor: %{status: :unavailable}}) do
    "idle Simulator scan unavailable"
  end

  defp thermal_summary(%{thermal_pressure: false} = system) do
    "thermal pressure: normal; #{System.temperature_summary(system)}"
  end

  defp thermal_summary(%{hot_processes: []} = system) do
    "thermal pressure: high; #{System.temperature_summary(system)}; " <>
      "no process uses at least 20% CPU"
  end

  defp thermal_summary(%{hot_processes: processes} = system) do
    suspects =
      Enum.map_join(processes, ", ", fn process ->
        "#{process.name} (PID #{process.pid}, CPU #{process.cpu_percent}%)"
      end)

    "thermal pressure: high; #{System.temperature_summary(system)}; suspects: #{suspects}"
  end

  defp history_target("cleanclip"), do: :cleanclip
  defp history_target("system"), do: :system
  defp history_target("thermal"), do: :thermal
  defp history_target("memory"), do: :memory
  defp history_target(target) when target in ["simulator", "simulators"], do: :simulators
  defp history_target(target) when target in ["build", "builds"], do: :builds
  defp history_target("apps"), do: :apps
  defp history_target(_target), do: :unknown

  defp fmt(nil), do: "-"
  defp fmt(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")

  defp record_build_cleanup(result) do
    details = %{
      removed: length(result.removed),
      reclaimed_bytes: result.reclaimed_bytes,
      failures: length(result.failures),
      xcode_skip: result.skipped.xcode,
      rust_skip: result.skipped.rust
    }

    Store.with_tables(fn _state, events ->
      Store.log_event(events, :builds, :cleanup_completed, details)
    end)
  end

  defp print_build_cleanup(result) do
    IO.puts(
      "build cleanup: removed #{length(result.removed)} directories, " <>
        "reclaimed #{result.reclaimed_bytes} bytes, failures=#{length(result.failures)}"
    )

    Enum.each(result.removed, fn removed ->
      IO.puts("  removed #{removed.kind}: #{removed.path} (#{removed.bytes} bytes)")
    end)

    Enum.each(result.skipped, fn
      {_kind, nil} -> :ok
      {kind, reason} -> IO.puts("  skipped #{kind}: #{reason}")
    end)

    Enum.each(result.failures, fn failure ->
      IO.puts("  failed #{failure.kind}: #{failure.path} (#{inspect(failure.reason)})")
    end)
  end
end
