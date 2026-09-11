defmodule Canaryd.Checker do
  @moduledoc """
  One full health-check round:

    1. L1 system: CPU/GPU temperature / thermal / load / memory
    2. Scan the macOS unresponsive state for third-party GUI apps
    3. Confirm and shut down long-idle Simulator devices
    4. Confirm and stop leftover Playwright Chrome for Testing
    5. User idle > 30min? -> skip the CleanClip probe
    6. L2 CleanClip process liveness (relaunch silently if dead)
    7. L3 CleanClip functional probe, state machine, silent auto-restart,
       notify only when blocked.
  """

  alias Canaryd.{
    CodexProcessMonitor,
    CodexProcesses,
    Duration,
    MemoryMonitor,
    MemoryProcesses,
    Notifier,
    PlaywrightBrowserMonitor,
    PlaywrightBrowsers,
    SimulatorMonitor,
    Simulators,
    StateMachine,
    Store,
    System,
    ThermalMonitor,
    UnresponsiveMonitor
  }

  alias Canaryd.Apps.{CleanClip, Unresponsive}

  def run do
    Store.with_tables(fn state, events ->
      idle = System.idle_duration()
      sys = System.check()
      record_system(state, events, sys)
      thermal_monitor = check_thermal_processes(state, events, sys)
      memory_monitor = check_idle_memory_processes(state, events, idle)
      simulator_monitor = check_idle_simulators(state, events)
      codex_process_monitor = check_idle_codex_processes(state, events, idle)
      playwright_browser_monitor = check_idle_playwright_browsers(state, events)

      sys =
        sys
        |> Map.put(:thermal_monitor, thermal_monitor)
        |> Map.put(:memory_monitor, memory_monitor)
        |> Map.put(:simulator_monitor, simulator_monitor)
        |> Map.put(:codex_process_monitor, codex_process_monitor)
        |> Map.put(:playwright_browser_monitor, playwright_browser_monitor)

      app_monitor = check_unresponsive_apps(state, events)

      if idle > Duration.minutes(30) do
        Store.log_event(events, :self, :skipped_idle, %{idle_duration: idle})
        {:skipped_idle, idle, sys, app_monitor}
      else
        cleanclip = check_cleanclip(state, events)
        {:checked, idle, sys, cleanclip, app_monitor}
      end
    end)
  end

  @doc "Runs only the temperature and thermal process checks."
  def run_thermal do
    Store.with_tables(fn state, events ->
      sys = System.check()
      thermal_monitor = check_thermal_processes(state, events, sys)

      {:thermal_checked, Map.put(sys, :thermal_monitor, thermal_monitor)}
    end)
  end

  defp check_thermal_processes(state, events, sys) do
    monitor_state =
      Store.get_value(state, :thermal_processes, ThermalMonitor.default_state())

    {new_monitor_state, actions} =
      ThermalMonitor.evaluate(
        monitor_state,
        sys.thermal_pressure,
        sys.hot_processes,
        DateTime.utc_now()
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

    delivery = deliver_temperature_warning(sys, suspects)
    Store.log_event(events, :thermal, :heat_alerted, Map.put(details, :delivery, delivery))

    :alerted
  end

  defp run_thermal_action(events, {:report, suspects}, sys) do
    delivery = deliver_temperature_warning(sys, suspects)

    Store.log_event(events, :thermal, :heat_suspects_reported, %{
      suspects: suspect_details(suspects),
      temperatures: temperature_details(sys),
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

    Store.log_event(events, :thermal, :heat_action_requested, details)

    summary = "#{System.temperature_summary(sys)}\n#{suspect_summary(suspects)}"

    case Notifier.choose_thermal_action(process.name, summary) do
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

  defp suspect_details(suspects), do: Enum.map(suspects, &process_details/1)

  defp temperature_details(sys) do
    Map.take(sys, [
      :cpu_temperature_c,
      :gpu_temperature_c,
      :battery_temperature_c,
      :temperature_source
    ])
  end

  defp deliver_temperature_warning(sys, suspects) do
    message = "#{System.temperature_summary(sys)}\n\nSuspects: #{suspect_summary(suspects)}"

    case Notifier.warn_temperature(message) do
      :ok ->
        :notification_scheduled

      {:error, reason} ->
        Notifier.notify("Mac temperature warning", String.replace(message, "\n\n", "; "))
        {:notification_fallback, inspect(reason)}
    end
  end

  defp suspect_summary(suspects) do
    Enum.map_join(suspects, ", ", fn process ->
      "#{process.name} (PID #{process.pid}, CPU #{process.cpu_percent}%)"
    end)
  end

  defp check_idle_memory_processes(state, events, idle_duration) do
    monitor_state =
      Store.get_value(state, :idle_memory_processes, MemoryMonitor.default_state())

    if idle_duration >= MemoryMonitor.minimum_idle() do
      case MemoryProcesses.scan() do
        {:ok, apps} ->
          {new_monitor_state, actions} =
            MemoryMonitor.evaluate(monitor_state, apps, idle_duration, DateTime.utc_now())

          Store.put_state(state, :idle_memory_processes, new_monitor_state)
          results = Enum.map(actions, &run_memory_action(events, &1))
          detected = Enum.count(apps, &MemoryMonitor.candidate?/1)

          %{status: :available, detected: detected, actions: results}

        {:error, reason} ->
          Store.put_state(
            state,
            :idle_memory_processes,
            MemoryMonitor.reset_observations(monitor_state)
          )

          %{status: :unavailable, detected: 0, actions: [], reason: reason}
      end
    else
      {new_monitor_state, []} =
        MemoryMonitor.evaluate(monitor_state, [], idle_duration, DateTime.utc_now())

      Store.put_state(state, :idle_memory_processes, new_monitor_state)
      %{status: :skipped_active, detected: 0, actions: []}
    end
  end

  defp run_memory_action(events, {:detected, app, count}) do
    details = app |> memory_details() |> Map.put(:count, count)
    Store.log_event(events, :memory, :idle_high_memory_detected, details)
    :detected
  end

  defp run_memory_action(events, {:close, app}) do
    case MemoryProcesses.close(app) do
      :ok ->
        details = memory_details(app)
        Store.log_event(events, :memory, :closed, details)

        Notifier.notify(
          "Mac Health",
          "Closed idle #{app.name} after it used #{app.rss_mb} MB of memory."
        )

        :closed

      {:error, reason} ->
        details = Map.put(memory_details(app), :reason, inspect(reason))
        Store.log_event(events, :memory, :close_failed, details)
        Notifier.notify("Mac Health", "Could not close idle high-memory app #{app.name}.")
        :close_failed
    end
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

  defp check_idle_simulators(state, events) do
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
          now
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
          results = Enum.map(actions, &{&1, run_simulator_action(state, events, &1)})
          notify_simulator_results(results)

          %{
            status: :available,
            booted: length(devices),
            detected:
              Enum.count(
                devices,
                &SimulatorMonitor.candidate?(&1, new_monitor_state.last_foreground_at, now)
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
  def run_simulator_action(state, events, {:shutdown, device}, simulators \\ Simulators) do
    monitor_state =
      Store.get_value(state, :idle_simulators, SimulatorMonitor.default_state())

    with {:ok, false} <- simulators.frontmost?(),
         {:ok, []} <- simulators.active_automation_processes(),
         true <-
           SimulatorMonitor.candidate?(
             device,
             Map.get(monitor_state, :last_foreground_at),
             DateTime.utc_now()
           ),
         :ok <- simulators.shutdown(device) do
      Store.log_event(events, :simulators, :shutdown, simulator_details(device))
      :shutdown
    else
      {:ok, true} ->
        {updated_state, []} =
          SimulatorMonitor.evaluate(monitor_state, [], true, false, DateTime.utc_now())

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

  defp check_idle_codex_processes(state, events, idle_duration) do
    monitor_state =
      Store.get_value(state, :idle_codex_processes, CodexProcessMonitor.default_state())

    if idle_duration >= CodexProcessMonitor.minimum_idle() do
      case CodexProcesses.scan() do
        {:ok, processes} ->
          {new_monitor_state, actions} =
            CodexProcessMonitor.evaluate(monitor_state, processes, idle_duration)

          Store.put_state(state, :idle_codex_processes, new_monitor_state)
          results = Enum.map(actions, &{&1, run_codex_process_action(events, &1)})
          notify_codex_process_results(results)

          %{
            status: :available,
            detected: length(processes),
            actions: Enum.map(results, &elem(&1, 1))
          }

        {:error, reason} ->
          Store.put_state(
            state,
            :idle_codex_processes,
            CodexProcessMonitor.reset_observations(monitor_state)
          )

          %{status: :unavailable, detected: 0, actions: [], reason: reason}
      end
    else
      {new_monitor_state, []} =
        CodexProcessMonitor.evaluate(monitor_state, [], idle_duration)

      Store.put_state(state, :idle_codex_processes, new_monitor_state)
      %{status: :skipped_active, detected: 0, actions: []}
    end
  end

  defp run_codex_process_action(events, {:detected, process, count}) do
    details = process |> codex_process_details() |> Map.put(:count, count)
    Store.log_event(events, :codex_processes, :idle_detected, details)
    :detected
  end

  defp run_codex_process_action(events, {:terminate, process}) do
    with true <- System.idle_duration() >= CodexProcessMonitor.minimum_idle(),
         :ok <- CodexProcesses.terminate(process) do
      Store.log_event(events, :codex_processes, :terminated, codex_process_details(process))
      :terminated
    else
      false ->
        codex_process_termination_skipped(events, process, :user_activity_resumed)

      :already_stopped ->
        codex_process_termination_skipped(events, process, :already_stopped)

      {:error, :process_identity_changed} ->
        codex_process_termination_skipped(events, process, :process_identity_changed)

      {:error, reason} ->
        details = Map.put(codex_process_details(process), :reason, inspect(reason))
        Store.log_event(events, :codex_processes, :termination_failed, details)
        :termination_failed
    end
  end

  defp codex_process_termination_skipped(events, process, reason) do
    details = Map.put(codex_process_details(process), :reason, reason)
    Store.log_event(events, :codex_processes, :termination_skipped, details)
    :termination_skipped
  end

  defp notify_codex_process_results(results) do
    terminated = Enum.count(results, &match?({{:terminate, _process}, :terminated}, &1))

    failed =
      Enum.count(results, &match?({{:terminate, _process}, :termination_failed}, &1))

    if terminated > 0 do
      Notifier.notify(
        "Mac Health",
        "Stopped #{terminated} idle Codex screen-control #{process_word(terminated)}."
      )
    end

    if failed > 0 do
      Notifier.notify(
        "Mac Health",
        "Could not stop #{failed} idle Codex screen-control #{process_word(failed)}."
      )
    end
  end

  defp process_word(1), do: "process"
  defp process_word(_count), do: "processes"

  defp codex_process_details(process) do
    Map.take(process, [:id, :kind, :pid, :ppid, :name])
  end

  defp check_idle_playwright_browsers(state, events) do
    monitor_state =
      Store.get_value(state, :idle_playwright_browsers, PlaywrightBrowserMonitor.default_state())

    with {:ok, browsers} <- PlaywrightBrowsers.scan(),
         {:ok, automation_processes} <- PlaywrightBrowsers.active_automation_processes() do
      automation_active = automation_processes != []

      {new_monitor_state, actions} =
        PlaywrightBrowserMonitor.evaluate(monitor_state, browsers, automation_active)

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

  defp check_unresponsive_apps(state, events) do
    monitor_state =
      Store.get_value(state, :unresponsive_apps, UnresponsiveMonitor.default_state())

    case Unresponsive.scan() do
      {:ok, apps} ->
        {new_monitor_state, actions} =
          UnresponsiveMonitor.evaluate(monitor_state, apps, DateTime.utc_now())

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

  defp record_system(state, events, sys) do
    sys_state = Store.get_state(state, :system)

    {new_sys_state, action} =
      if sys.warnings == [] do
        StateMachine.transition(sys_state, :ok, DateTime.utc_now())
      else
        StateMachine.transition(sys_state, :fail, DateTime.utc_now())
      end

    Store.put_state(state, :system, new_sys_state)

    case action do
      :blocked ->
        Store.log_event(events, :system, :system_warn, %{warnings: sys.warnings})
        Notifier.notify("Mac Health", "System degraded: #{Enum.join(sys.warnings, "; ")}")

      :recovered ->
        Store.log_event(events, :system, :recovered, %{})

      _ ->
        :ok
    end
  end

  defp check_cleanclip(state, events) do
    now = DateTime.utc_now()
    st = Store.get_state(state, :cleanclip)

    {st, probe_result} =
      if CleanClip.process_alive?() do
        {st, CleanClip.probe()}
      else
        Store.log_event(events, :cleanclip, :process_dead, %{})
        CleanClip.start()
        {st, CleanClip.probe()}
      end

    result = if probe_result == :ok, do: :ok, else: :fail
    {new_st, action} = StateMachine.transition(st, result, now)
    Store.put_state(state, :cleanclip, new_st)

    case {result, action} do
      {:ok, :recovered} ->
        Store.log_event(events, :cleanclip, :recovered, %{})

      {:fail, :restart} ->
        Store.log_event(events, :cleanclip, :probe_fail, %{reason: inspect(probe_result)})

        if CleanClip.restart() do
          Store.log_event(events, :cleanclip, :restarted, %{})
        end

      {:fail, :blocked} ->
        Store.log_event(events, :cleanclip, :blocked, %{reason: inspect(probe_result)})

        Notifier.notify(
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
