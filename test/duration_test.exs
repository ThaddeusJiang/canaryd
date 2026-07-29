defmodule Canaryd.DurationTest do
  use ExUnit.Case, async: true

  alias Canaryd.Duration

  test "uses milliseconds as the internal time unit" do
    assert Duration.milliseconds(250) == 250
    assert Duration.seconds(30) == 30_000
    assert Duration.minutes(5) == 300_000
    assert Duration.hours(1) == 3_600_000
    assert Duration.days(1) == 86_400_000
  end

  test "converts only at external boundaries" do
    assert Duration.from_external(1_800_000_000_000, :nanosecond) == 1_800_000
    assert Duration.to_external(300_000, :second) == 300
  end

  test "compares DateTime values in milliseconds" do
    earlier = ~U[2026-07-29 00:00:00.000Z]
    later = ~U[2026-07-29 00:00:01.250Z]

    assert Duration.between(later, earlier) == 1_250
  end
end
