defmodule Canaryd.PlaywrightBrowserMonitorTest do
  use ExUnit.Case, async: true

  alias Canaryd.PlaywrightBrowserMonitor

  defp browser(overrides \\ %{}) do
    Map.merge(
      %{
        id: {:chrome_for_testing, 737, "Fri Sep 11 00:00:01 2026"},
        kind: :chrome_for_testing,
        pid: 737,
        ppid: 1,
        started_at: "Fri Sep 11 00:00:01 2026",
        name: "Chrome for Testing"
      },
      overrides
    )
  end

  test "confirms leftover browsers after three observations without requiring user idle" do
    assert PlaywrightBrowserMonitor.required_observations() == 3

    {state, actions} =
      PlaywrightBrowserMonitor.evaluate(
        PlaywrightBrowserMonitor.default_state(),
        [browser()],
        false
      )

    assert actions == [{:detected, browser(), 1}]

    {state, actions} = PlaywrightBrowserMonitor.evaluate(state, [browser()], false)
    assert actions == [{:detected, browser(), 2}]

    {state, actions} = PlaywrightBrowserMonitor.evaluate(state, [browser()], false)
    assert actions == [{:terminate, browser()}]
    assert PlaywrightBrowserMonitor.pending_browsers(state) == []
  end

  test "Playwright runners, a missing browser, and PID reuse reset confirmation" do
    {state, _actions} =
      PlaywrightBrowserMonitor.evaluate(
        PlaywrightBrowserMonitor.default_state(),
        [browser()],
        false
      )

    {state, []} = PlaywrightBrowserMonitor.evaluate(state, [browser()], true)

    {state, actions} = PlaywrightBrowserMonitor.evaluate(state, [browser()], false)
    assert actions == [{:detected, browser(), 1}]

    {state, []} = PlaywrightBrowserMonitor.evaluate(state, [], false)

    replacement =
      browser(%{
        id: {:chrome_for_testing, 737, "Fri Sep 11 02:00:01 2026"},
        started_at: "Fri Sep 11 02:00:01 2026"
      })

    {_state, actions} = PlaywrightBrowserMonitor.evaluate(state, [replacement], false)
    assert actions == [{:detected, replacement, 1}]
  end

  test "deduplicates identical browser identities" do
    {_state, actions} =
      PlaywrightBrowserMonitor.evaluate(
        PlaywrightBrowserMonitor.default_state(),
        [browser(), browser()],
        false
      )

    assert actions == [{:detected, browser(), 1}]
  end
end
