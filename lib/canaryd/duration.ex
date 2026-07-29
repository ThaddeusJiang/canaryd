defmodule Canaryd.Duration do
  @moduledoc """
  Defines milliseconds as the internal time unit.

  Convert a duration only when an external API uses another unit.
  """

  @scale 1_000

  def milliseconds(value) when is_integer(value), do: value
  def seconds(value) when is_integer(value), do: value * @scale
  def minutes(value) when is_integer(value), do: seconds(value * 60)
  def hours(value) when is_integer(value), do: minutes(value * 60)
  def days(value) when is_integer(value), do: hours(value * 24)

  def from_external(value, unit) when is_integer(value) do
    System.convert_time_unit(value, unit, :millisecond)
  end

  def to_external(value, unit) when is_integer(value) do
    System.convert_time_unit(value, :millisecond, unit)
  end

  def between(later, earlier) do
    DateTime.diff(later, earlier, :millisecond)
  end

  def add(datetime, duration) when is_integer(duration) do
    DateTime.add(datetime, duration, :millisecond)
  end
end
