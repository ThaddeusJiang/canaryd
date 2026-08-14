defmodule Canaryd.UnresponsiveMonitorTest do
  use ExUnit.Case, async: true

  alias Canaryd.{Duration, UnresponsiveMonitor}

  @t0 ~U[2026-07-26 00:00:00Z]

  defp later(value), do: Duration.add(@t0, Duration.seconds(value))

  defp app(overrides \\ %{}) do
    Map.merge(
      %{
        id: "com.example.writer",
        name: "Writer",
        pid: 42,
        recovery: :automatic,
        bundle_id: "com.example.writer",
        bundle_path: "/Applications/Writer.app"
      },
      overrides
    )
  end

  defp cursor_ui_service do
    %{
      id: "com.apple.TextInputUI.xpc.CursorUIViewService",
      name: "CursorUIViewService",
      pid: 805,
      recovery: :automatic,
      bundle_id: "com.apple.TextInputUI.xpc.CursorUIViewService",
      bundle_path:
        "/System/Library/PrivateFrameworks/TextInputUIMacHelper.framework/Versions/A/XPCServices/CursorUIViewService.xpc"
    }
  end

  test "exposes the restart cooldown" do
    assert UnresponsiveMonitor.restart_cooldown() == 3_600_000
  end

  test "requires two consecutive observations before restart" do
    {state, first_actions} =
      UnresponsiveMonitor.evaluate(UnresponsiveMonitor.default_state(), [app()], @t0)

    assert first_actions == [{:detected, app(), 1}]

    {state, second_actions} =
      UnresponsiveMonitor.evaluate(state, [app()], later(300))

    assert second_actions == [{:restart, app()}]
    assert UnresponsiveMonitor.pending_apps(state) == []
  end

  test "a responsive round resets confirmation" do
    {state, _actions} =
      UnresponsiveMonitor.evaluate(UnresponsiveMonitor.default_state(), [app()], @t0)

    {state, []} = UnresponsiveMonitor.evaluate(state, [], later(300))

    {_state, actions} =
      UnresponsiveMonitor.evaluate(state, [app()], later(600))

    assert actions == [{:detected, app(), 1}]
  end

  test "an unavailable scan resets confirmation but keeps restart cooldowns" do
    previous_restart = later(-300)

    state = %{
      UnresponsiveMonitor.default_state()
      | observations: %{app().id => %{app: app(), count: 1}},
        restarts: %{app().id => previous_restart},
        blocked: MapSet.new([app().id])
    }

    reset_state = UnresponsiveMonitor.reset_observations(state)

    assert UnresponsiveMonitor.pending_apps(reset_state) == []
    assert reset_state.restarts == %{app().id => previous_restart}
    assert reset_state.blocked == MapSet.new([app().id])
  end

  test "restarts CursorUIViewService after two observations" do
    {state, [{:detected, _service, 1}]} =
      UnresponsiveMonitor.evaluate(
        UnresponsiveMonitor.default_state(),
        [cursor_ui_service()],
        @t0
      )

    {state, actions} =
      UnresponsiveMonitor.evaluate(
        state,
        [cursor_ui_service()],
        later(300)
      )

    assert actions == [{:restart, cursor_ui_service()}]
    assert UnresponsiveMonitor.pending_apps(state) == []
  end

  test "blocks one repeated hang during restart cooldown" do
    {state, _actions} =
      UnresponsiveMonitor.evaluate(UnresponsiveMonitor.default_state(), [app()], @t0)

    {state, [{:restart, _app}]} =
      UnresponsiveMonitor.evaluate(state, [app()], later(300))

    {state, [{:detected, _app, 1}]} =
      UnresponsiveMonitor.evaluate(state, [app()], later(600))

    {state, actions} =
      UnresponsiveMonitor.evaluate(state, [app()], later(900))

    assert actions == [{:blocked, app()}]

    {_state, actions} =
      UnresponsiveMonitor.evaluate(state, [app()], later(1_200))

    assert actions == []
  end

  test "allows a new restart after cooldown" do
    {state, _actions} =
      UnresponsiveMonitor.evaluate(UnresponsiveMonitor.default_state(), [app()], @t0)

    {state, [{:restart, _app}]} =
      UnresponsiveMonitor.evaluate(state, [app()], later(300))

    {state, _actions} =
      UnresponsiveMonitor.evaluate(state, [app()], later(3_601))

    {_state, actions} =
      UnresponsiveMonitor.evaluate(state, [app()], later(3_901))

    assert actions == [{:restart, app()}]
  end

  test "tracks apps independently" do
    second = app(%{id: "com.example.chat", name: "Chat", bundle_id: "com.example.chat", pid: 84})

    {state, _actions} =
      UnresponsiveMonitor.evaluate(UnresponsiveMonitor.default_state(), [app(), second], @t0)

    {_state, actions} =
      UnresponsiveMonitor.evaluate(state, [app(), second], later(300))

    assert actions == [{:restart, app()}, {:restart, second}]
  end
end
