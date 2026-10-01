defmodule Canaryd.Checker do
  @moduledoc """
  One full health-check round:

    1. L1 system: CPU/GPU temperature / thermal / load / memory
    2. Scan the macOS unresponsive state for third-party GUI apps
    3. Confirm and shut down long-idle Simulator devices
    4. Confirm and stop leftover Playwright Chrome for Testing
    6. L2 CleanClip process liveness (relaunch silently if dead)
    7. L3 CleanClip functional probe, state machine, silent auto-restart,
       notify only when blocked.
  """

  alias Canaryd.{
    BuildCleanup,
    BuildProcessMonitor,
    BuildProcesses,
    CodexProcessMonitor,
    CodexProcesses,
    DiskPressureConfig,
    DiskPressureMonitor,
    Duration,
    MemoryMonitor,
    MemoryProcesses,
    Notifier,
    PlaywrightBrowserMonitor,
    PlaywrightBrowsers,
    PolicyConfig,
    SimulatorMonitor,
    Simulators,
    StateMachine,
    Store,
    System,
    SwapMonitor,
    ThermalMonitor,
    UnresponsiveMonitor
  }

  alias Canaryd.Apps.{CleanClip, Unresponsive}

  def run do
    with {:ok, policy} <- PolicyConfig.read_all() do
      Store.with_tables(fn state, events ->
        idle = System.idle_duration()
        sys = System.check(policy: policy)
        record_system(state, events, sys, policy: policy)
        storage_monitor = check_disk_pressure(state, events, sys, policy: policy)
        thermal_monitor = check_thermal_processes(state, events, sys, policy)

        memory_monitor =
          check_memory_processes(state, events, swap_usage: sys.swap_usage, policy: policy)

        build_process_monitor = check_build_processes(state, events, policy: policy)
        simulator_monitor = check_idle_simulators(state, events, policy)
        codex_process_monitor = check_idle_codex_processes(state, events, idle, policy: policy)
        playwright_browser_monitor = check_idle_playwright_browsers(state, events, policy)

        sys =
          sys
          |> Map.put(:storage_monitor, storage_monitor)
          |> Map.put(:thermal_monitor, thermal_monitor)
          |> Map.put(:memory_monitor, memory_monitor)
          |> Map.put(:build_process_monitor, build_process_monitor)
          |> Map.put(:simulator_monitor, simulator_monitor)
          |> Map.put(:codex_process_monitor, codex_process_monitor)
          |> Map.put(:playwright_browser_monitor, playwright_browser_monitor)

        app_monitor = check_unresponsive_apps(state, events, policy)

        cleanclip = check_cleanclip(state, events, policy: policy)
        {:checked, idle, sys, cleanclip, app_monitor}
      end)
    end
  end

  @doc "Runs only the temperature and thermal process checks."
  def run_thermal do
    with {:ok, policy} <- PolicyConfig.read_all() do
      Store.with_tables(fn state, events ->
        sys = System.check(policy: policy)
        thermal_monitor = check_thermal_processes(state, events, sys, policy)

        {:thermal_checked, Map.put(sys, :thermal_monitor, thermal_monitor)}
      end)
    end
  end

  defp check_thermal_processes(state, events, sys, policy) do
    monitor_state =
      Store.get_value(state, :thermal_processes, ThermalMonitor.default_state())

    {new_monitor_state, actions} =
      ThermalMonitor.evaluate(
        monitor_state,
        sys.thermal_pressure,
        sys.hot_processes,
        DateTime.utc_now(),
        policy
      )

    Store.put_state(state, :thermal_processes, new_monitor_state)
    results = Enum.map(actions, &run_thermal_action(events, &1, sys))

    %{pressure: sys.thermal_pressure, suspects: sys.hot_processes, actions: results}
  end

  defp run_thermal_action(events, {:alert, process, suspects}, sys) do
    details =
      process
      |> process_details()
      |> Map.put(:suspects, suspect_details(suspects))
      |> Map.put(:temperatures, temperature_details(sys))
      |> Map.put(:pressure_warnings, sys.pressure_warnings)

    delivery = deliver_pressure_warning(sys, suspects)
    Store.log_event(events, :thermal, :heat_alerted, Map.put(details, :delivery, delivery))

    :alerted
  end

  defp run_thermal_action(events, {:report, suspects}, sys) do
    delivery = deliver_pressure_warning(sys, suspects)

    Store.log_event(events, :thermal, :heat_suspects_reported, %{
      suspects: suspect_details(suspects),
      temperatures: temperature_details(sys),
      pressure_warnings: sys.pressure_warnings,
      delivery: delivery
    })

    :reported
  end

  defp run_thermal_action(events, {:choose, process, suspects}, sys) do
    details =
      process
      |> process_details()
      |> Map.put(:suspects, suspect_details(suspects))
      |> Map.put(:temperatures, temperature_details(sys))
      |> Map.put(:pressure_warnings, sys.pressure_warnings)

    Store.log_event(events, :thermal, :heat_action_requested, details)

    {title, pressure_summary} = System.pressure_notification(sys)
    summary = "#{pressure_summary}\n#{suspect_summary(suspects)}"

    case Notifier.choose_pressure_action(title, process.name, summary) do
      {:ok, :restart} -> restart_hot_app(events, process)
      {:ok, :close} -> close_hot_app(events, process)
      {:ok, :ignore} -> ignore_hot_app(events, process)
      {:error, reason} -> thermal_action_failed(events, process, reason)
    end
  end

  defp restart_hot_app(events, process) do
    case Unresponsive.restart(process) do
      :ok ->
        Store.log_event(events, :thermal, :restarted, process_details(process))
        :restarted

      {:error, reason} ->
        thermal_action_failed(events, process, reason)
    end
  end

  defp close_hot_app(events, process) do
    case Unresponsive.close(process) do
      :ok ->
        Store.log_event(events, :thermal, :closed, process_details(process))
        :closed

      {:error, reason} ->
        thermal_action_failed(events, process, reason)
    end
  end

  defp ignore_hot_app(events, process) do
    Store.log_event(events, :thermal, :ignored, process_details(process))
    :ignored
  end

  defp thermal_action_failed(events, process, reason) do
    details = Map.put(process_details(process), :reason, inspect(reason))
    Store.log_event(events, :thermal, :action_failed, details)
    Notifier.notify("Mac Health", "The selected thermal action for #{process.name} failed.")
    :action_failed
  end

  defp process_details(process) do
    Map.take(process, [:id, :name, :pid, :cpu_percent, :bundle_path])
  end

  @doc false
  def check_disk_pressure(state, events, sys, options \\ []) do
    monitor_state =
      Store.get_value(state, :disk_pressure, DiskPressureMonitor.default_state())

    cleaner = Keyword.get(options, :cleaner, &BuildCleanup.run/0)

    emergency_cleaner =
      Keyword.get(options, :emergency_cleaner, fn -> BuildCleanup.run(mode: :emergency) end)

    notifier = Keyword.get(options, :notifier, &Notifier.notify/2)
    now = Keyword.get(options, :now, DateTime.utc_now())
    usage = Map.get(sys, :disk_usage)

    threshold_result =
      case Map.fetch(sys, :disk_threshold) do
        {:ok, result} -> result
        :error -> DiskPressureConfig.read()
      end

    policy = Keyword.get(options, :policy, PolicyConfig.defaults())

    case threshold_result do
      {:ok, threshold_bytes} ->
        {new_state, actions} =
          DiskPressureMonitor.evaluate(monitor_state, usage, now, threshold_bytes, policy)

        Store.put_state(state, :disk_pressure, new_state)

        results =
          Enum.map(actions, fn
            {:emergency_cleanup, _usage} = action ->
              run_disk_action(events, action, emergency_cleaner, notifier)

            action ->
              run_disk_action(events, action, cleaner, notifier)
          end)

        %{
          status: if(is_map(usage), do: :available, else: :unavailable),
          pressured: Canaryd.Disk.pressure?(usage, threshold_bytes),
          actions: results,
          usage: usage,
          threshold_bytes: threshold_bytes
        }

      {:error, reason} ->
        %{status: :unavailable, pressured: false, actions: [], usage: usage, reason: reason}
    end
  end

  defp run_disk_action(events, {:cleanup, usage}, cleaner, notifier) do
    run_disk_cleanup(events, usage, cleaner, notifier, :pressure)
  end

  defp run_disk_action(events, {:emergency_cleanup, usage}, cleaner, notifier) do
    run_disk_cleanup(events, usage, cleaner, notifier, :emergency)
  end

  defp run_disk_cleanup(events, usage, cleaner, notifier, kind) do
    case cleaner.() do
      {:ok, result} ->
        details = %{
          used_percent: usage.used_percent,
          available_bytes: usage.available_bytes,
          removed: length(result.removed),
          reclaimed_bytes: result.reclaimed_bytes,
          terminated_build_processes: Map.get(result, :terminated_build_processes, 0),
          failures: length(result.failures),
          skipped: result.skipped
        }

        Store.log_event(events, :storage, cleanup_event(kind, :completed), details)

        if result.reclaimed_bytes == 0 do
          notifier.(
            "Mac Health",
            "Data volume has #{Canaryd.Disk.format_bytes(usage.available_bytes)} available; no validated build artifact or cache was removed."
          )
        end

        :cleaned

      {:error, :locked} ->
        Store.log_event(events, :storage, cleanup_event(kind, :skipped), %{reason: :locked})
        :skipped

      {:error, reason} ->
        Store.log_event(events, :storage, cleanup_event(kind, :failed), %{reason: inspect(reason)})

        notifier.("Mac Health", "Data volume cleanup failed: #{inspect(reason)}")
        :failed
    end
  end

  defp cleanup_event(:pressure, :completed), do: :pressure_cleanup_completed
  defp cleanup_event(:pressure, :skipped), do: :pressure_cleanup_skipped
  defp cleanup_event(:pressure, :failed), do: :pressure_cleanup_failed
  defp cleanup_event(:emergency, :completed), do: :emergency_cleanup_completed
  defp cleanup_event(:emergency, :skipped), do: :emergency_cleanup_skipped
  defp cleanup_event(:emergency, :failed), do: :emergency_cleanup_failed

  defp suspect_details(suspects), do: Enum.map(suspects, &process_details/1)

  defp temperature_details(sys) do
    Map.take(sys, [
      :cpu_temperature_c,
      :gpu_temperature_c,
      :battery_temperature_c,
      :temperature_source
    ])
  end

  defp deliver_pressure_warning(sys, suspects) do
    {title, summary} = System.pressure_notification(sys)
    message = "#{summary}\n\nHigh-CPU candidates: #{suspect_summary(suspects)}"

    case Notifier.warn_pressure(title, message) do
      :ok ->
        :notification_scheduled

      {:error, reason} ->
        {:notification_failed, inspect(reason)}
    end
  end

  defp suspect_summary([]), do: "none above the CPU threshold"

  defp suspect_summary(suspects) do
    Enum.map_join(suspects, ", ", fn process ->
      "#{process.name} (PID #{process.pid}, CPU #{process.cpu_percent}%)"
    end)
  end

  @doc false
  def check_memory_processes(state, events, options \\ []) do
    monitor_state = Store.get_value(state, :idle_memory_processes, MemoryMonitor.default_state())
    scanner = Keyword.get(options, :scanner, &MemoryProcesses.scan/0)
    notifier = Keyword.get(options, :notifier, &Notifier.notify/2)
    now = Keyword.get(options, :now, DateTime.utc_now())
    swap_usage = Keyword.get(options, :swap_usage)
    policy = Keyword.get(options, :policy, PolicyConfig.defaults())

    case scanner.() do
      {:ok, apps} ->
        {new_state, actions} = MemoryMonitor.evaluate(monitor_state, apps, 0, now, policy)
        Store.put_state(state, :idle_memory_processes, new_state)
        results = Enum.map(actions, &run_memory_action(events, &1, notifier))
        swap_state = Store.get_value(state, :swap_pressure, SwapMonitor.default_state())

        {new_swap_state, swap_actions} =
          SwapMonitor.evaluate(swap_state, swap_usage, apps, now, policy)

        Store.put_state(state, :swap_pressure, new_swap_state)
        swap_results = Enum.map(swap_actions, &run_swap_action(events, &1, notifier))

        %{
          status: :available,
          detected: Enum.count(apps, &MemoryMonitor.candidate?(&1, policy)),
          actions: results,
          swap_monitor: %{
            status: if(is_map(swap_usage), do: :available, else: :unavailable),
            actions: swap_results
          }
        }

      {:error, reason} ->
        Store.put_state(
          state,
          :idle_memory_processes,
          MemoryMonitor.reset_observations(monitor_state)
        )

        swap_state = Store.get_value(state, :swap_pressure, SwapMonitor.default_state())
        {new_swap_state, _actions} = SwapMonitor.evaluate(swap_state, nil, [], now, policy)
        Store.put_state(state, :swap_pressure, new_swap_state)

        %{status: :unavailable, detected: 0, actions: [], reason: reason}
    end
  end

  defp run_swap_action(events, {:alert, usage, apps}, notifier) do
    details = %{
      used_bytes: usage.used_bytes,
      total_bytes: usage.total_bytes,
      related_apps: apps
    }

    Store.log_event(events, :memory, :swap_growth_alerted, details)

    suspects =
      Enum.map_join(apps, ", ", fn app ->
        "#{app.name} (PID #{app.pid}, RSS #{app.rss_mb} MB)"
      end)

    suspects = if suspects == "", do: "none", else: suspects

    message =
      "Swap has grown to #{Canaryd.Swap.format_bytes(usage.used_bytes)}. " <>
        "Related RSS suspects (not proof of cause): #{suspects}."

    notifier.("Mac Health", message)
    :alerted
  end

  @doc false
  def check_build_processes(state, events, options \\ []) do
    monitor_state =
      Store.get_value(state, :build_processes, BuildProcessMonitor.default_state())

    scanner = Keyword.get(options, :scanner, &BuildProcesses.scan/0)
    notifier = Keyword.get(options, :notifier, &Notifier.notify/2)
    now = Keyword.get(options, :now, DateTime.utc_now())
    policy = Keyword.get(options, :policy, PolicyConfig.defaults())

    case scanner.() do
      {:ok, processes} ->
        {new_state, actions} = BuildProcessMonitor.evaluate(monitor_state, processes, now, policy)
        Store.put_state(state, :build_processes, new_state)
        results = Enum.map(actions, &run_build_process_action(events, &1, notifier))

        %{
          status: :available,
          detected: length(processes),
          detached: Enum.count(processes, & &1.detached),
          actions: results
        }

      {:error, reason} ->
        Store.put_state(state, :build_processes, BuildProcessMonitor.default_state())
        %{status: :unavailable, detected: 0, detached: 0, actions: [], reason: reason}
    end
  end

  defp run_build_process_action(events, {:alert, process}, notifier) do
    details = Map.take(process, [:id, :name, :pid, :ppid, :cpu_percent, :rss_mb, :detached])
    Store.log_event(events, :builds, :detached_build_process_alerted, details)

    notifier.(
      "Mac Health",
      "Detached #{process.name} (PID #{process.pid}) is still running. Review it before stopping the build."
    )

    :alerted
  end

  defp run_memory_action(events, {:detected, app, count}, _notifier) do
    Store.log_event(
      events,
      :memory,
      :high_memory_detected,
      Map.put(memory_details(app), :count, count)
    )

    :detected
  end

  defp run_memory_action(events, {:alert, app}, notifier) do
    Store.log_event(events, :memory, :high_memory_alerted, memory_details(app))

    notifier.(
      "Mac Health",
      "#{app.name} has kept using #{app.rss_mb} MB of memory. Review it when convenient."
    )

    :alerted
  end

  defp memory_details(app) do
    Map.take(app, [
      :id,
      :name,
      :pid,
      :rss_mb,
      :cpu_percent,
      :bundle_id,
      :bundle_path
    ])
  end

  defp check_idle_simulators(state, events, policy) do
    monitor_state =
      Store.get_value(state, :idle_simulators, SimulatorMonitor.default_state())

    with {:ok, devices} <- Simulators.scan(),
         {:ok, simulator_foreground} <- Simulators.frontmost?(),
         {:ok, automation_processes} <- Simulators.active_automation_processes() do
      automation_active = automation_processes != []
      now = DateTime.utc_now()

      {new_monitor_state, actions} =
        SimulatorMonitor.evaluate(
          monitor_state,
          devices,
          simulator_foreground,
          automation_active,
          now,
          policy
        )

      Store.put_state(state, :idle_simulators, new_monitor_state)

      cond do
        simulator_foreground ->
          %{
            status: :skipped_foreground,
            booted: length(devices),
            detected: 0,
            actions: []
          }

        automation_active ->
          %{
            status: :skipped_automation,
            booted: length(devices),
            detected: 0,
            actions: [],
            automation_processes: automation_processes
          }

        true ->
          results =
            Enum.map(actions, &{&1, run_simulator_action(state, events, &1, Simulators, policy)})

          notify_simulator_results(results)

          %{
            status: :available,
            booted: length(devices),
            detected:
              Enum.count(
                devices,
                &SimulatorMonitor.candidate?(
                  &1,
                  new_monitor_state.last_foreground_at,
                  now,
                  policy
                )
              ),
            actions: Enum.map(results, &elem(&1, 1))
          }
      end
    else
      {:error, reason} ->
        Store.put_state(
          state,
          :idle_simulators,
          SimulatorMonitor.reset_observations(monitor_state)
        )

        %{status: :unavailable, booted: 0, detected: 0, actions: [], reason: reason}
    end
  end

  @doc false
  def run_simulator_action(
        state,
        events,
        {:shutdown, device},
        simulators \\ Simulators,
        policy \\ PolicyConfig.defaults()
      ) do
    monitor_state =
      Store.get_value(state, :idle_simulators, SimulatorMonitor.default_state())

    with {:ok, false} <- simulators.frontmost?(),
         {:ok, []} <- simulators.active_automation_processes(),
         true <-
           SimulatorMonitor.candidate?(
             device,
             Map.get(monitor_state, :last_foreground_at),
             DateTime.utc_now(),
             policy
           ),
         :ok <- simulators.shutdown(device) do
      Store.log_event(events, :simulators, :shutdown, simulator_details(device))
      :shutdown
    else
      {:ok, true} ->
        {updated_state, []} =
          SimulatorMonitor.evaluate(monitor_state, [], true, false, DateTime.utc_now(), policy)

        :ok = Store.put_state(state, :idle_simulators, updated_state)
        simulator_shutdown_skipped(events, device, :simulator_foreground)

      false ->
        simulator_shutdown_skipped(events, device, :recent_activity)

      {:ok, [_process | _processes]} ->
        simulator_shutdown_skipped(events, device, :automation_started)

      :already_stopped ->
        simulator_shutdown_skipped(events, device, :already_stopped)

      {:error, :device_activity_changed} ->
        simulator_shutdown_skipped(events, device, :device_activity_changed)

      {:error, reason} ->
        details = Map.put(simulator_details(device), :reason, inspect(reason))
        Store.log_event(events, :simulators, :shutdown_failed, details)
        :shutdown_failed
    end
  end

  defp simulator_shutdown_skipped(events, device, reason) do
    details = Map.put(simulator_details(device), :reason, reason)
    Store.log_event(events, :simulators, :shutdown_skipped, details)
    :shutdown_skipped
  end

  defp notify_simulator_results(results) do
    shutdown_names =
      for {{:shutdown, device}, :shutdown} <- results, do: device.name

    failed_names =
      for {{:shutdown, device}, :shutdown_failed} <- results, do: device.name

    if shutdown_names != [] do
      Notifier.notify(
        "Mac Health",
        "Shut down idle Simulators: #{Enum.join(shutdown_names, ", ")}."
      )
    end

    if failed_names != [] do
      Notifier.notify(
        "Mac Health",
        "Could not shut down idle Simulators: #{Enum.join(failed_names, ", ")}."
      )
    end
  end

  defp simulator_details(device) do
    Map.take(device, [:udid, :name, :runtime, :state, :last_used_at])
  end

  @doc "Inspects Codex helpers; dry runs do not advance observations."
  def run_codex(options \\ []) do
    with {:ok, policy} <- PolicyConfig.read_all() do
      Store.with_tables(fn state, events ->
        check_idle_codex_processes(
          state,
          events,
          System.idle_duration(),
          Keyword.put(options, :policy, policy)
        )
      end)
    end
  end

  @doc false
  def check_idle_codex_processes(state, events, idle_duration, options \\ []) do
    monitor_state =
      Store.get_value(state, :idle_codex_processes, CodexProcessMonitor.default_state())

    scanner = Keyword.get(options, :scanner, &CodexProcesses.scan/0)
    dry_run = Keyword.get(options, :dry_run, false)
    now = Keyword.get(options, :now, Elixir.System.system_time(:millisecond))
    policy = Keyword.get(options, :policy, PolicyConfig.defaults())

    case scanner.() do
      {:ok, processes} ->
        {new_state, actions} =
          CodexProcessMonitor.evaluate(monitor_state, processes, idle_duration, now, policy)

        results =
          if dry_run do
            Enum.map(
              actions,
              &{&1, elem(&1, 0)}
            )
          else
            Store.put_state(state, :idle_codex_processes, new_state)
            results = Enum.map(actions, &{&1, run_codex_process_action(events, &1, options)})
            results
          end

        reports =
          Enum.map(processes, fn process ->
            reason = CodexProcessMonitor.protection_reason(process, idle_duration)

            status =
              Enum.find_value(results, :protected, fn {action, result} ->
                if elem(action, 1).id == process.id, do: result
              end)

            observation = new_state.observations[process.id]

            Map.merge(codex_process_details(process), %{
              status: status,
              reason: reason,
              quiet_duration: if(observation, do: now - observation.quiet_since, else: 0)
            })
          end)

        %{
          status: :available,
          detected: length(processes),
          protected: Enum.count(reports, &(&1.status == :protected)),
          actions: Enum.map(results, &elem(&1, 1)),
          processes: reports
        }

      {:error, reason} ->
        unless dry_run,
          do:
            Store.put_state(
              state,
              :idle_codex_processes,
              CodexProcessMonitor.reset_observations(monitor_state)
            )

        %{status: :unavailable, detected: 0, actions: [], processes: [], reason: reason}
    end
  end

  defp run_codex_process_action(events, {:detected, process, count}, _options) do
    details = process |> codex_process_details() |> Map.put(:count, count)
    Store.log_event(events, :codex_processes, :idle_detected, details)
    :detected
  end

  # Empty does not mean abandoned: the installed app server does not recover
  # an existing MCP connection after its childless REPL is terminated.
  defp run_codex_process_action(events, {:quiet, process}, _options) do
    Store.log_event(
      events,
      :codex_processes,
      :quiet_retained,
      Map.put(codex_process_details(process), :reason, :session_activity_unknown)
    )

    :quiet
  end

  defp codex_process_details(process) do
    Map.take(process, [:id, :kind, :pid, :ppid, :name])
  end

  defp process_word(1), do: "process"
  defp process_word(_count), do: "processes"

  defp check_idle_playwright_browsers(state, events, policy) do
    monitor_state =
      Store.get_value(state, :idle_playwright_browsers, PlaywrightBrowserMonitor.default_state())

    with {:ok, browsers} <- PlaywrightBrowsers.scan(),
         {:ok, automation_processes} <- PlaywrightBrowsers.active_automation_processes() do
      automation_active = automation_processes != []

      {new_monitor_state, actions} =
        PlaywrightBrowserMonitor.evaluate(monitor_state, browsers, automation_active, policy)

      Store.put_state(state, :idle_playwright_browsers, new_monitor_state)

      if automation_active do
        %{
          status: :skipped_automation,
          detected: 0,
          actions: [],
          automation_processes: automation_processes
        }
      else
        results = Enum.map(actions, &{&1, run_playwright_browser_action(events, &1)})
        notify_playwright_browser_results(results)

        %{
          status: :available,
          detected: length(browsers),
          actions: Enum.map(results, &elem(&1, 1))
        }
      end
    else
      {:error, reason} ->
        Store.put_state(
          state,
          :idle_playwright_browsers,
          PlaywrightBrowserMonitor.reset_observations(monitor_state)
        )

        %{status: :unavailable, detected: 0, actions: [], reason: reason}
    end
  end

  defp run_playwright_browser_action(events, {:detected, browser, count}) do
    details = browser |> playwright_browser_details() |> Map.put(:count, count)
    Store.log_event(events, :playwright_browsers, :idle_detected, details)
    :detected
  end

  defp run_playwright_browser_action(events, {:terminate, browser}) do
    with {:ok, []} <- PlaywrightBrowsers.active_automation_processes(),
         :ok <- PlaywrightBrowsers.terminate(browser) do
      Store.log_event(
        events,
        :playwright_browsers,
        :terminated,
        playwright_browser_details(browser)
      )

      :terminated
    else
      {:ok, [_process | _processes]} ->
        playwright_browser_termination_skipped(events, browser, :automation_started)

      :already_stopped ->
        playwright_browser_termination_skipped(events, browser, :already_stopped)

      {:error, :process_identity_changed} ->
        playwright_browser_termination_skipped(events, browser, :process_identity_changed)

      {:error, :browser_became_frontmost} ->
        playwright_browser_termination_skipped(events, browser, :browser_became_frontmost)

      {:error, reason} ->
        details = Map.put(playwright_browser_details(browser), :reason, inspect(reason))
        Store.log_event(events, :playwright_browsers, :termination_failed, details)
        :termination_failed
    end
  end

  defp playwright_browser_termination_skipped(events, browser, reason) do
    details = Map.put(playwright_browser_details(browser), :reason, reason)
    Store.log_event(events, :playwright_browsers, :termination_skipped, details)
    :termination_skipped
  end

  defp notify_playwright_browser_results(results) do
    terminated = Enum.count(results, &match?({{:terminate, _browser}, :terminated}, &1))
    failed = Enum.count(results, &match?({{:terminate, _browser}, :termination_failed}, &1))

    if terminated > 0 do
      Notifier.notify(
        "Mac Health",
        "Stopped #{terminated} idle Playwright Chrome for Testing #{process_word(terminated)}."
      )
    end

    if failed > 0 do
      Notifier.notify(
        "Mac Health",
        "Could not stop #{failed} idle Playwright Chrome for Testing #{process_word(failed)}."
      )
    end
  end

  defp playwright_browser_details(browser) do
    Map.take(browser, [:id, :kind, :pid, :ppid, :name])
  end

  defp check_unresponsive_apps(state, events, policy) do
    monitor_state =
      Store.get_value(state, :unresponsive_apps, UnresponsiveMonitor.default_state())

    case Unresponsive.scan() do
      {:ok, apps} ->
        {new_monitor_state, actions} =
          UnresponsiveMonitor.evaluate(monitor_state, apps, DateTime.utc_now(), policy)

        Store.put_state(state, :unresponsive_apps, new_monitor_state)
        results = Enum.map(actions, &run_app_action(events, &1))

        %{status: :available, detected: length(apps), actions: results}

      {:error, reason} ->
        Store.put_state(
          state,
          :unresponsive_apps,
          UnresponsiveMonitor.reset_observations(monitor_state)
        )

        %{status: :unavailable, detected: 0, actions: [], reason: reason}
    end
  end

  defp run_app_action(events, {:detected, app, count}) do
    Store.log_event(events, :apps, :hang_detected, Map.put(app_details(app), :count, count))
    :detected
  end

  defp run_app_action(events, {:restart, app}) do
    case Unresponsive.restart(app) do
      :ok ->
        Store.log_event(events, :apps, :restarted, app_details(app))
        :restarted

      {:error, reason} ->
        details = Map.put(app_details(app), :reason, inspect(reason))
        Store.log_event(events, :apps, :restart_failed, details)

        notify_app_recovery_failure(
          app,
          "#{app.name} was unresponsive and could not restart."
        )

        :restart_failed
    end
  end

  defp run_app_action(events, {:blocked, app}) do
    Store.log_event(events, :apps, :blocked, app_details(app))

    notify_app_recovery_failure(
      app,
      "#{app.name} is still unresponsive after an automatic restart."
    )

    :blocked
  end

  defp notify_app_recovery_failure(app, message) do
    unless Unresponsive.silent_recovery?(app) do
      Notifier.notify("Mac Health", message)
    end
  end

  defp app_details(app) do
    Map.take(app, [
      :id,
      :name,
      :pid,
      :activation_policy,
      :bundle_id,
      :bundle_path,
      :recovery
    ])
  end

  @doc false
  def record_system(state, events, sys, options \\ []) do
    now = Keyword.get(options, :now, DateTime.utc_now())
    notifier = Keyword.get(options, :notifier, &Notifier.notify/2)
    policy = Keyword.get(options, :policy, PolicyConfig.defaults())
    sys_state = Store.get_state(state, :system)

    system_policy = %{
      policy
      | cleanclip_restart_cooldown: policy.system_restart_cooldown,
        cleanclip_failure_confirmations: policy.system_failure_confirmations
    }

    {new_sys_state, action} =
      if sys.warnings == [] do
        StateMachine.transition(sys_state, :ok, now, system_policy)
      else
        StateMachine.transition(sys_state, :fail, now, system_policy)
      end

    Store.put_state(state, :system, new_sys_state)

    case action do
      :blocked ->
        Store.log_event(events, :system, :system_warn, %{warnings: sys.warnings})
        other_warnings = sys.warnings -- sys.pressure_warnings

        if other_warnings != [] do
          notifier.("Mac Health", "System degraded: #{Enum.join(other_warnings, "; ")}")
        end

      :recovered ->
        Store.log_event(events, :system, :recovered, %{})

      _ ->
        :ok
    end
  end

  @doc false
  def check_cleanclip(state, events, options \\ []) do
    now = Keyword.get(options, :now, DateTime.utc_now())
    alive = Keyword.get(options, :alive?, &CleanClip.process_alive?/0)
    starter = Keyword.get(options, :starter, &CleanClip.start/0)
    st = Store.get_state(state, :cleanclip)
    policy = Keyword.get(options, :policy, PolicyConfig.defaults())
    was_alive = alive.()

    running =
      if was_alive do
        true
      else
        Store.log_event(events, :cleanclip, :process_dead, %{})
        starter.()
      end

    cond do
      not running ->
        result =
          record_cleanclip_probe(
            state,
            events,
            st,
            {:fail, :process_not_running},
            now,
            Keyword.put(options, :restarter, fn -> false end)
          )

        Store.log_event(events, :cleanclip, :process_start_failed, %{})
        result

      was_alive and st.last_probe == :ok and
          Duration.between(now, st.updated_at) in 0..(policy.cleanclip_probe_interval - 1) ->
        %{probe: :skipped, action: :probe_not_due, failures: st.consecutive_failures}

      true ->
        probe = Keyword.get(options, :probe, &CleanClip.probe/0)
        record_cleanclip_probe(state, events, st, probe.(), now, options)
    end
  end

  defp record_cleanclip_probe(state, events, st, probe_result, now, options) do
    restarter = Keyword.get(options, :restarter, &CleanClip.restart/0)
    notifier = Keyword.get(options, :notifier, &Notifier.notify/2)
    result = if probe_result == :ok, do: :ok, else: :fail
    policy = Keyword.get(options, :policy, PolicyConfig.defaults())
    {new_st, action} = StateMachine.transition(st, result, now, policy)
    Store.put_state(state, :cleanclip, new_st)

    case {result, action} do
      {:ok, :recovered} ->
        Store.log_event(events, :cleanclip, :recovered, %{})

      {:fail, :restart} ->
        Store.log_event(events, :cleanclip, :probe_fail, %{reason: inspect(probe_result)})

        if restarter.() do
          Store.log_event(events, :cleanclip, :restarted, %{})
        end

      {:fail, :blocked} ->
        Store.log_event(events, :cleanclip, :blocked, %{reason: inspect(probe_result)})

        notifier.(
          "Mac Health",
          "CleanClip unresponsive; auto-restart failed. Please check manually."
        )

      {:fail, :wait} ->
        Store.log_event(events, :cleanclip, :probe_fail, %{reason: inspect(probe_result)})

      _ ->
        :ok
    end

    %{probe: result, action: action, failures: new_st.consecutive_failures}
  end
end
