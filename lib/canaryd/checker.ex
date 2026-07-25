defmodule Canaryd.Checker do
  @moduledoc """
  One full health-check round:

    1. User idle > 30min? -> record L1 only, skip probes (user away, silence is normal)
    2. L1 system: thermal / load / memory
    3. L2 CleanClip process liveness (relaunch silently if dead)
    4. L3 CleanClip functional probe, state machine, silent auto-restart,
       notify only when blocked.
  """

  alias Canaryd.{Notifier, StateMachine, Store, System}
  alias Canaryd.Apps.CleanClip

  @idle_skip_sec 1_800

  def run do
    Store.with_tables(fn state, events ->
      idle = System.idle_seconds()
      sys = System.check()
      record_system(state, events, sys)

      if idle > @idle_skip_sec do
        Store.log_event(events, :self, :skipped_idle, %{idle_seconds: idle})
        {:skipped_idle, idle, sys}
      else
        cleanclip = check_cleanclip(state, events)
        {:checked, idle, sys, cleanclip}
      end
    end)
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
        Notifier.notify("Mac Health", "CleanClip unresponsive; auto-restart failed. Please check manually.")

      {:fail, :wait} ->
        Store.log_event(events, :cleanclip, :probe_fail, %{reason: inspect(probe_result)})

      _ ->
        :ok
    end

    %{probe: result, action: action, failures: new_st.consecutive_failures}
  end
end
