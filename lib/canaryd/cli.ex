defmodule Canaryd.CLI do
  @moduledoc "escript entry for checks, status, target history, setup, and version output."

  alias Canaryd.{
    BuildCleanup,
    BuildCleanupConfig,
    Checker,
    CodexProcessMonitor,
    Duration,
    MemoryMonitor,
    NotificationHelper,
    Paths,
    PlaywrightBrowserMonitor,
    SimulatorMonitor,
    Setup,
    Store,
    System,
    ThermalMonitor,
    UnresponsiveMonitor
  }

  alias Canaryd.Apps.CleanClip

  def main(argv, options \\ [])

  def main([command] = argv, options)
      when command in ["check", "thermal-check", "clean", "reclaim"] do
    ensure_helper =
      Keyword.get(options, :ensure_notification_helper, &NotificationHelper.ensure_installed/0)

    case ensure_helper.() do
      :ok -> dispatch(argv, options)
      {:error, reason} -> IO.puts("#{command} failed: #{inspect(reason)}")
    end
  end

  def main(argv, options) do
    dispatch(argv, options)
  end

  defp dispatch([command], options) when command in ["start", "install"] do
    start = Keyword.get(options, :start, &Setup.install/0)

    case start.() do
      :ok -> IO.puts("background monitoring started")
      {:error, reason} -> IO.puts("start failed: #{inspect(reason)}")
    end
  end

  defp dispatch([command], options) when command in ["stop", "uninstall"] do
    stop = Keyword.get(options, :stop, &Setup.uninstall/0)

    case stop.() do
      :ok -> IO.puts("background monitoring stopped")
      {:error, reason} -> IO.puts("stop failed: #{inspect(reason)}")
    end
  end

  defp dispatch(["reclaim" | flags], options) when flags in [[], ["--dry-run"]] do
    reclaimer = Keyword.get(options, :reclaimer, &Checker.run_codex/1)

    case reclaimer.(dry_run: flags == ["--dry-run"]) do
      %{status: :available} = result ->
        IO.puts("Codex helpers: #{result.detected}, protected: #{result.protected}")

        Enum.each(result.processes, fn process ->
          IO.puts("  #{process.name} (PID #{process.pid}): #{reclaim_status(process)}")
        end)

        IO.puts(
          "Automatic Codex termination is disabled: existing tool sessions do not reconnect safely."
        )

      {:error, :locked} ->
        IO.puts("another check is running, skipping")

      %{status: :unavailable, reason: reason} ->
        IO.puts("process scan unavailable: #{inspect(reason)}")
    end
  end

  defp dispatch(["clean"], options) do
    build_cleanup = Keyword.get(options, :build_cleanup, &BuildCleanup.run/0)

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

  defp dispatch(["config", "build-retention"], options) do
    options
    |> Keyword.get(:home, Paths.home_dir())
    |> BuildCleanupConfig.read()
    |> print_build_retention()
  end

  defp dispatch(["config", "build-retention", value], options) do
    value
    |> BuildCleanupConfig.set(Keyword.get(options, :home, Paths.home_dir()))
    |> print_build_retention()
  end

  defp dispatch(argv, _options), do: dispatch(argv)

  defp dispatch([command]) when command in ["--version", "version"] do
    IO.puts("canaryd #{Application.spec(:canaryd, :vsn)}")
  end

  defp dispatch(["check"]) do
    case Checker.run() do
      {:error, :locked} ->
        IO.puts("another check is running, skipping")

      {:checked, _idle, sys, cc, apps} ->
        IO.puts(
          "cleanclip: #{cc.probe} (#{cc.action}), failures=#{cc.failures}; " <>
            "system warnings: #{inspect(sys.warnings)}; #{thermal_summary(sys)}; " <>
            "#{memory_summary(sys)}; #{simulator_summary(sys)}; " <>
            "#{codex_process_summary(sys)}; #{playwright_browser_summary(sys)}"
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
      IO.puts("high-memory apps: #{format_memory_apps(pending_memory_apps)}")

      simulator_state =
        Store.get_value(state, :idle_simulators, SimulatorMonitor.default_state())

      pending_simulators = SimulatorMonitor.pending_devices(simulator_state)
      IO.puts("idle Simulators pending: #{format_simulators(pending_simulators)}")

      codex_process_state =
        Store.get_value(state, :idle_codex_processes, CodexProcessMonitor.default_state())

      pending_codex_processes = CodexProcessMonitor.pending_processes(codex_process_state)

      IO.puts(
        "idle Codex screen-control processes: " <>
          format_codex_processes(pending_codex_processes)
      )

      playwright_browser_state =
        Store.get_value(
          state,
          :idle_playwright_browsers,
          PlaywrightBrowserMonitor.default_state()
        )

      pending_playwright_browsers =
        PlaywrightBrowserMonitor.pending_browsers(playwright_browser_state)

      IO.puts(
        "idle Playwright Chrome for Testing: " <>
          format_playwright_browsers(pending_playwright_browsers)
      )
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

  defp dispatch(_argv) do
    IO.puts("""
    canaryd - Mac health monitor

    usage:
      canaryd check              run one check round (launchd does this every 5 min)
      canaryd thermal-check      run one thermal check now
      canaryd status             current health snapshot
      canaryd reclaim [--dry-run]  inspect quiet Codex helpers; --dry-run preserves observations
      canaryd clean              remove stale Xcode/Cargo artifacts and eligible Bazel caches
      canaryd config build-retention [Nh]  show or set build retention (default: 24h, range: 1h..87600h)
      canaryd history [target]   event timeline (cleanclip, system, thermal, memory, simulators, codex, playwright, builds, apps)
      canaryd start              start background monitoring (also after login)
      canaryd stop               stop background monitoring until the next start
      canaryd --version          show the installed version
    """)
  end

  defp reclaim_status(%{status: :detected, quiet_duration: quiet}) do
    "observing (#{div(quiet, Duration.minutes(1))}/30 min quiet)"
  end

  defp reclaim_status(%{status: :quiet}), do: "kept: quiet, session ownership unknown"
  defp reclaim_status(%{reason: :working_children}), do: "kept: has child processes"
  defp reclaim_status(%{reason: :session_activity_unknown}), do: "kept: session activity unknown"

  defp reclaim_status(_), do: "kept: activity unavailable"

  defp print_build_retention({:ok, retention}) do
    IO.puts("build retention: #{BuildCleanupConfig.format(retention)}")
  end

  defp print_build_retention({:error, reason}) do
    IO.puts("build retention failed: #{inspect(reason)}; expected 1h..87600h")
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

  defp format_codex_processes([]), do: "none"

  defp format_codex_processes(processes) do
    Enum.map_join(processes, ", ", fn process ->
      "#{process.name} (PID #{process.pid})"
    end)
  end

  defp format_playwright_browsers([]), do: "none"

  defp format_playwright_browsers(browsers) do
    Enum.map_join(browsers, ", ", fn browser ->
      "#{browser.name} (PID #{browser.pid})"
    end)
  end

  defp memory_summary(%{memory_monitor: %{status: :available} = monitor}) do
    "high-memory apps=#{monitor.detected}, actions=#{inspect(monitor.actions)}"
  end

  defp memory_summary(%{memory_monitor: %{status: :unavailable}}) do
    "idle memory scan unavailable"
  end

  defp simulator_summary(%{simulator_monitor: %{status: :skipped_foreground}}) do
    "idle Simulator scan: Simulator is in the foreground"
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

  defp codex_process_summary(%{codex_process_monitor: %{status: :available} = monitor}) do
    "Codex helpers=#{monitor.detected}, protected=#{monitor.protected}, " <>
      "actions=#{inspect(monitor.actions)}"
  end

  defp codex_process_summary(%{codex_process_monitor: %{status: :unavailable}}) do
    "idle Codex process scan unavailable"
  end

  defp playwright_browser_summary(%{
         playwright_browser_monitor: %{status: :skipped_automation} = monitor
       }) do
    names = Enum.map_join(monitor.automation_processes, ", ", & &1.name)
    "idle Playwright browser scan: automation active (#{names})"
  end

  defp playwright_browser_summary(%{playwright_browser_monitor: %{status: :available} = monitor}) do
    "idle Playwright Chrome for Testing=#{monitor.detected}, " <>
      "actions=#{inspect(monitor.actions)}"
  end

  defp playwright_browser_summary(%{playwright_browser_monitor: %{status: :unavailable}}) do
    "idle Playwright browser scan unavailable"
  end

  @doc false
  def thermal_summary(system) do
    Enum.join([pressure_summary(system) | system.warnings], "; ")
  end

  defp pressure_summary(%{thermal_status: :unavailable} = system) do
    "thermal pressure: unavailable; #{System.temperature_summary(system)}"
  end

  defp pressure_summary(%{thermal_pressure: false} = system) do
    "thermal pressure: normal; #{System.temperature_summary(system)}"
  end

  defp pressure_summary(%{hot_processes: []} = system) do
    "thermal pressure: high; #{System.temperature_summary(system)}; " <>
      "no process uses at least 20% CPU"
  end

  defp pressure_summary(%{hot_processes: processes} = system) do
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

  defp history_target(target) when target in ["codex", "codex-processes"],
    do: :codex_processes

  defp history_target(target) when target in ["playwright", "playwright-browsers"],
    do: :playwright_browsers

  defp history_target(target) when target in ["build", "builds"], do: :builds
  defp history_target("apps"), do: :apps
  defp history_target(_target), do: :unknown

  defp fmt(nil), do: "-"

  defp fmt(%DateTime{} = datetime) do
    format_datetime(datetime, local_utc_offset(datetime))
  end

  @doc false
  def format_datetime(%DateTime{} = datetime, utc_offset) when is_integer(utc_offset) do
    local = Duration.add(datetime, Duration.from_external(utc_offset, :second))
    "#{Calendar.strftime(local, "%Y-%m-%d %H:%M:%S")} #{format_utc_offset(utc_offset)}"
  end

  defp local_utc_offset(datetime) do
    universal = DateTime.to_naive(datetime)

    local =
      universal
      |> NaiveDateTime.to_erl()
      |> :calendar.universal_time_to_local_time()
      |> NaiveDateTime.from_erl!()

    local
    |> NaiveDateTime.diff(universal, :millisecond)
    |> Duration.to_external(:second)
  end

  defp format_utc_offset(utc_offset) do
    sign = if utc_offset < 0, do: "-", else: "+"
    total = div(abs(utc_offset), 60)
    hour = total |> div(60) |> Integer.to_string() |> String.pad_leading(2, "0")
    minute = total |> rem(60) |> Integer.to_string() |> String.pad_leading(2, "0")

    "UTC#{sign}#{hour}:#{minute}"
  end

  defp record_build_cleanup(result) do
    details = %{
      removed: length(result.removed),
      reclaimed_bytes: result.reclaimed_bytes,
      failures: length(result.failures),
      xcode_skip: result.skipped.xcode,
      rust_skip: result.skipped.rust,
      bazel_skip: result.skipped.bazel,
      bazel_repository_skip: Map.get(result.skipped, :bazel_repository),
      sccache: result.sccache
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

    if result.sccache do
      cache = result.sccache

      IO.puts(
        "  sccache: removed #{cache.removed_objects} objects, " <>
          "reclaimed #{cache.reclaimed_bytes} bytes, kept #{cache.kept_objects} objects"
      )
    end

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
