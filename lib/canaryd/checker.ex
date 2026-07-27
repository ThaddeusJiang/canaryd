defmodule Canaryd.Checker do
  @moduledoc """
  One full health-check round:

    1. L1 system: thermal / load / memory
    2. Scan the macOS unresponsive state for third-party GUI apps
    3. User idle > 30min? -> skip the CleanClip probe
    4. L2 CleanClip process liveness (relaunch silently if dead)
    5. L3 CleanClip functional probe, state machine, silent auto-restart,
       notify only when blocked.
  """

  alias Canaryd.{Notifier, StateMachine, Store, System, ThermalMonitor, UnresponsiveMonitor}
  alias Canaryd.Apps.{CleanClip, Unresponsive}

  @idle_skip_sec 1_800

  def run do
    Store.with_tables(fn state, events ->
      idle = System.idle_seconds()
      sys = System.check()
      record_system(state, events, sys)
      thermal_monitor = check_thermal_processes(state, events, sys)
      sys = Map.put(sys, :thermal_monitor, thermal_monitor)
      app_monitor = check_unresponsive_apps(state, events)

      if idle > @idle_skip_sec do
        Store.log_event(events, :self, :skipped_idle, %{idle_seconds: idle})
        {:skipped_idle, idle, sys, app_monitor}
      else
        cleanclip = check_cleanclip(state, events)
        {:checked, idle, sys, cleanclip, app_monitor}
      end
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
    results = Enum.map(actions, &run_thermal_action(events, &1))

    %{pressure: sys.thermal_pressure, suspects: sys.hot_processes, actions: results}
  end

  defp run_thermal_action(events, {:detected, process, suspects}) do
    details = Map.put(process_details(process), :suspects, suspect_details(suspects))
    Store.log_event(events, :thermal, :heat_suspect_detected, details)
    :detected
  end

  defp run_thermal_action(events, {:report, suspects}) do
    Store.log_event(events, :thermal, :heat_suspects_reported, %{
      suspects: suspect_details(suspects)
    })

    Notifier.notify("Mac Health", "High temperature pressure: #{suspect_summary(suspects)}")
    :reported
  end

  defp run_thermal_action(events, {:choose, process, suspects}) do
    details = Map.put(process_details(process), :suspects, suspect_details(suspects))
    Store.log_event(events, :thermal, :heat_action_requested, details)

    case Notifier.choose_thermal_action(process.name, suspect_summary(suspects)) do
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

  defp suspect_summary(suspects) do
    Enum.map_join(suspects, ", ", fn process ->
      "#{process.name} (PID #{process.pid}, CPU #{process.cpu_percent}%)"
    end)
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
        Notifier.notify("Mac Health", "#{app.name} was unresponsive and could not restart.")
        :restart_failed
    end
  end

  defp run_app_action(events, {:choose, app}) do
    Notifier.notify(
      "Mac Health",
      "#{app.name} is not responding. Choose Close or Restart in the action dialog."
    )

    case Notifier.choose_app_action(app.name) do
      {:ok, :restart} -> restart_selected_app(events, app)
      {:ok, :close} -> close_selected_app(events, app)
      {:ok, :ignore} -> ignore_selected_app(events, app)
      {:error, reason} -> app_action_failed(events, app, reason)
    end
  end

  defp run_app_action(events, {:blocked, app}) do
    Store.log_event(events, :apps, :blocked, app_details(app))
    Notifier.notify("Mac Health", "#{app.name} is still unresponsive after an automatic restart.")
    :blocked
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

  defp restart_selected_app(events, app) do
    case Unresponsive.restart(app) do
      :ok ->
        Store.log_event(events, :apps, :restarted, app_details(app))
        :restarted

      {:error, reason} ->
        app_action_failed(events, app, reason)
    end
  end

  defp close_selected_app(events, app) do
    case Unresponsive.close(app) do
      :ok ->
        Store.log_event(events, :apps, :closed, app_details(app))
        :closed

      {:error, reason} ->
        app_action_failed(events, app, reason)
    end
  end

  defp ignore_selected_app(events, app) do
    Store.log_event(events, :apps, :ignored, app_details(app))
    :ignored
  end

  defp app_action_failed(events, app, reason) do
    details = Map.put(app_details(app), :reason, inspect(reason))
    Store.log_event(events, :apps, :action_failed, details)
    Notifier.notify("Mac Health", "The selected action for #{app.name} failed.")
    :action_failed
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
