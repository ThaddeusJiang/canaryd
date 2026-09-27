defmodule Canaryd.SwapMonitorTest do
  use ExUnit.Case, async: true

  alias Canaryd.{Duration, SwapMonitor}

  @t0 ~U[2026-09-23 00:00:00Z]
  @gb 1_024 * 1_024 * 1_024

  defp usage(gb), do: %{total_bytes: 10 * @gb, used_bytes: gb * @gb, free_bytes: (10 - gb) * @gb}

  defp apps do
    [%{id: "com.example.app", name: "Example", pid: 42, rss_mb: 3_000.0, cpu_percent: 0.2}]
  end

  test "alerts after sustained swap growth and names related RSS suspects" do
    {state, []} = SwapMonitor.evaluate(SwapMonitor.default_state(), usage(3), apps(), @t0)

    {state, []} =
      SwapMonitor.evaluate(state, usage(3), apps(), Duration.add(@t0, Duration.minutes(5)))

    {_state, [{:alert, _usage, [%{name: "Example"}]}]} =
      SwapMonitor.evaluate(state, usage(4), apps(), Duration.add(@t0, Duration.minutes(10)))
  end

  test "does not alert on a single global swap sample" do
    {_state, []} = SwapMonitor.evaluate(SwapMonitor.default_state(), usage(8), apps(), @t0)
  end

  test "frequent checks retain spaced confirmations without counting each check" do
    {state, []} = SwapMonitor.evaluate(SwapMonitor.default_state(), usage(3), apps(), @t0)

    {state, []} =
      Enum.reduce(1..11, {state, []}, fn minute, {state, []} ->
        SwapMonitor.evaluate(state, usage(3), apps(), Duration.add(@t0, Duration.minutes(minute)))
      end)

    {_state, [{:alert, _, _}]} =
      SwapMonitor.evaluate(state, usage(4), apps(), Duration.add(@t0, Duration.minutes(12)))
  end
end
