defmodule Canaryd.NamingConventionTest do
  use ExUnit.Case, async: true

  @snake_case_time_suffix ~r/\b[a-z][a-z0-9_]*_(?:sec|secs|second|seconds|ms|msec|millisecond|milliseconds|nanosecond|nanoseconds|minute|minutes|hour|hours|day|days)\b/
  @camel_case_time_suffix ~r/\b[a-z][A-Za-z0-9]*(?:Sec|Secs|Second|Seconds|Ms|Millisecond|Milliseconds|Nanosecond|Nanoseconds|Minute|Minutes|Hour|Hours|Day|Days)\b/
  @datetime_second_unit ~r/DateTime\.(?:add|diff)\([^\n]*:second/

  test "time units are not identifier suffixes" do
    violations =
      source_files()
      |> Enum.flat_map(&file_violations/1)

    assert violations == [],
           "time units must be documented outside identifier names:\n#{Enum.join(violations, "\n")}"
  end

  test "DateTime calculations use the internal millisecond unit" do
    violations =
      source_files()
      |> Enum.flat_map(&datetime_unit_violations/1)

    assert violations == [],
           "DateTime calculations must use milliseconds:\n#{Enum.join(violations, "\n")}"
  end

  defp source_files do
    root = Path.expand("..", __DIR__)

    ["lib/**/*.{ex,exs}", "priv/**/*.{swift}", "test/**/*.{ex,exs}"]
    |> Enum.flat_map(&Path.wildcard(Path.join(root, &1)))
    |> Enum.reject(&String.ends_with?(&1, "naming_convention_test.exs"))
  end

  defp file_violations(path) do
    path
    |> File.stream!()
    |> Stream.with_index(1)
    |> Enum.flat_map(fn {line, line_number} ->
      if time_suffix?(line) and not legacy_data_key?(path, line) do
        ["#{Path.relative_to_cwd(path)}:#{line_number}: #{String.trim(line)}"]
      else
        []
      end
    end)
  end

  defp time_suffix?(line) do
    Regex.match?(@snake_case_time_suffix, line) or
      Regex.match?(@camel_case_time_suffix, line)
  end

  defp legacy_data_key?(path, line) do
    Path.basename(path) in ["store.ex", "store_test.exs"] and
      String.contains?(line, "idle_" <> "seconds")
  end

  defp datetime_unit_violations(path) do
    path
    |> File.stream!()
    |> Stream.with_index(1)
    |> Enum.flat_map(fn {line, line_number} ->
      if Regex.match?(@datetime_second_unit, line) do
        ["#{Path.relative_to_cwd(path)}:#{line_number}: #{String.trim(line)}"]
      else
        []
      end
    end)
  end
end
