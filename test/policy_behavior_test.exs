defmodule Canaryd.PolicyBehaviorTest do
  use ExUnit.Case, async: true

  alias Canaryd.{
    BuildProcessMonitor,
    CodexProcessMonitor,
    DiskPressureMonitor,
    Duration,
    MemoryMonitor,
    PlaywrightBrowserMonitor,
    PolicyConfig,
    SimulatorMonitor,
    StateMachine,
    Store,
    SwapMonitor,
    ThermalMonitor,
    UnresponsiveMonitor
  }

  @now ~U[2026-09-23 00:00:00Z]
  @gib 1_024 * 1_024 * 1_024

  defp later(minutes), do: Duration.add(@now, Duration.minutes(minutes))
  defp policy(changes), do: Map.merge(PolicyConfig.defaults(), changes)

  test "memory and swap use changed limits and confirmation counts" do
    app = %{
      id: "sample",
      pid: 42,
      name: "Sample",
      rss_mb: 1_500.0,
      cpu_percent: 0.5,
      actionable: true
    }

    memory_policy = policy(%{memory_rss: 2_000, memory_confirmations: 2})

    assert {_, []} =
             MemoryMonitor.evaluate(MemoryMonitor.default_state(), [app], 0, @now, memory_policy)

    memory_policy = %{memory_policy | memory_rss: 1_200}

    {state, [{:detected, _, 1}]} =
      MemoryMonitor.evaluate(MemoryMonitor.default_state(), [app], 0, @now, memory_policy)

    assert {_, [{:alert, ^app}]} =
             MemoryMonitor.evaluate(state, [app], 0, later(5), memory_policy)

    usage = fn gib -> %{used_bytes: gib * @gib, total_bytes: 8 * @gib} end
    swap_policy = policy(%{swap_min_growth: 1_024, swap_confirmations: 2})

    {state, []} =
      SwapMonitor.evaluate(SwapMonitor.default_state(), usage.(2), [app], @now, swap_policy)

    assert {_, []} = SwapMonitor.evaluate(state, usage.(2.5), [app], later(5), swap_policy)

    swap_policy = %{swap_policy | swap_min_growth: 512}

    {state, []} =
      SwapMonitor.evaluate(SwapMonitor.default_state(), usage.(2), [app], @now, swap_policy)

    assert {_, [{:alert, _, [_]}]} =
             SwapMonitor.evaluate(state, usage.(2.5), [app], later(5), swap_policy)
  end

  test "thermal and storage cooldowns use changed values" do
    hot = %{id: "hot", name: "Hot", pid: 42, actionable: true}

    thermal_policy =
      policy(%{thermal_confirmations: 3, thermal_alert_cooldown: Duration.minutes(20)})

    {state, [{:alert, _, _}]} =
      ThermalMonitor.evaluate(ThermalMonitor.default_state(), true, [hot], @now, thermal_policy)

    {state, []} = ThermalMonitor.evaluate(state, true, [hot], later(5), thermal_policy)

    assert {_, [{:choose, _, _}]} =
             ThermalMonitor.evaluate(state, true, [hot], later(10), thermal_policy)

    usage = %{available_bytes: 5 * @gib, used_percent: 99}
    storage_policy = policy(%{storage_cleanup_cooldown: Duration.minutes(90)})

    {state, [{:cleanup, _}]} =
      DiskPressureMonitor.evaluate(
        DiskPressureMonitor.default_state(),
        usage,
        @now,
        20 * @gib,
        storage_policy
      )

    assert {_, []} =
             DiskPressureMonitor.evaluate(state, usage, later(60), 20 * @gib, storage_policy)

    assert {_, [{:cleanup, _}]} =
             DiskPressureMonitor.evaluate(state, usage, later(90), 20 * @gib, storage_policy)
  end

  test "automatic-action confirmation and inactivity thresholds are configurable" do
    app = %{id: "writer", name: "Writer", pid: 42}

    policy =
      policy(%{
        unresponsive_confirmations: 3,
        playwright_confirmations: 4,
        simulator_min_idle: Duration.minutes(30)
      })

    {state, [{:detected, _, 1}]} =
      UnresponsiveMonitor.evaluate(UnresponsiveMonitor.default_state(), [app], @now, policy)

    {state, [{:detected, _, 2}]} = UnresponsiveMonitor.evaluate(state, [app], later(5), policy)
    assert {_, [{:restart, ^app}]} = UnresponsiveMonitor.evaluate(state, [app], later(10), policy)

    browser = %{id: {:browser, 42}, name: "Chrome", pid: 42}

    state =
      Enum.reduce(1..3, PlaywrightBrowserMonitor.default_state(), fn _, state ->
        {next, [{:detected, _, _}]} =
          PlaywrightBrowserMonitor.evaluate(state, [browser], false, policy)

        next
      end)

    assert {_, [{:terminate, ^browser}]} =
             PlaywrightBrowserMonitor.evaluate(state, [browser], false, policy)

    device = %{udid: "device", name: "iPhone", state: :booted, last_used_at: later(-20)}

    assert {_, []} =
             SimulatorMonitor.evaluate(
               SimulatorMonitor.default_state(),
               [device],
               false,
               false,
               @now,
               policy
             )

    assert {_, [{:shutdown, ^device}]} =
             SimulatorMonitor.evaluate(
               SimulatorMonitor.default_state(),
               [device],
               false,
               false,
               later(10),
               policy
             )
  end

  test "detached builds and quiet Codex hosts use changed confirmation windows" do
    build = %{id: {:clang, 42}, pid: 42, detached: true}
    build_policy = policy(%{build_process_confirmations: 2})

    {state, []} =
      BuildProcessMonitor.evaluate(
        BuildProcessMonitor.default_state(),
        [build],
        @now,
        build_policy
      )

    assert {_, [{:alert, ^build}]} =
             BuildProcessMonitor.evaluate(state, [build], later(5), build_policy)

    codex = %{
      id: {:node_repl, 43},
      kind: :node_repl,
      pid: 43,
      ppid: 1,
      name: "node_repl",
      cpu_time: 1,
      protection: nil
    }

    codex_policy = policy(%{codex_confirmations: 2, codex_min_idle: Duration.minutes(10)})

    {state, [{:detected, _, 1}]} =
      CodexProcessMonitor.evaluate(
        CodexProcessMonitor.default_state(),
        [codex],
        0,
        0,
        codex_policy
      )

    {state, [{:detected, _, 2}]} =
      CodexProcessMonitor.evaluate(state, [codex], 0, Duration.minutes(5), codex_policy)

    assert {_, [{:quiet, ^codex}]} =
             CodexProcessMonitor.evaluate(state, [codex], 0, Duration.minutes(10), codex_policy)
  end

  test "state machine uses changed cooldown and failure confirmations" do
    policy =
      policy(%{
        cleanclip_restart_cooldown: Duration.minutes(90),
        cleanclip_failure_confirmations: 2
      })

    {state, :restart} = StateMachine.transition(Store.default_state(), :fail, @now, policy)
    {state, :blocked} = StateMachine.transition(state, :fail, later(5), policy)
    assert {_, :wait} = StateMachine.transition(state, :fail, later(60), policy)
  end
end
