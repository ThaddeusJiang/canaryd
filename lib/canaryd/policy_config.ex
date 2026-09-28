defmodule Canaryd.PolicyConfig do
  @moduledoc """
  Persistent, validated decision thresholds for health checks and automatic actions.

  Every key has a safe default. Invalid or unreadable files fail the entire check
  before any action, rather than silently weakening a protection rule.
  """

  alias Canaryd.{ConfigFile, Duration, Paths}

  @max_size 64
  @schema %{
    system_load_factor: {:decimal, 0.8, 0.1, 4.0, ""},
    system_chip_temperature: {:decimal, 70.0, 40.0, 110.0, "C"},
    system_hot_process_cpu: {:decimal, 20.0, 1.0, 400.0, "%"},
    system_memory_free: {:integer, 10, 1, 50, "%"},
    system_restart_cooldown: {:minutes, Duration.hours(1), 1, 1_440, "m"},
    system_failure_confirmations: {:integer, 3, 1, 20, ""},
    thermal_confirmations: {:integer, 2, 2, 20, ""},
    thermal_alert_cooldown: {:minutes, Duration.minutes(15), 1, 1_440, "m"},
    thermal_prompt_cooldown: {:minutes, Duration.hours(1), 15, 1_440, "m"},
    memory_rss: {:integer, 1_024, 128, 65_536, "M"},
    memory_cpu: {:decimal, 1.0, 0.0, 100.0, "%"},
    memory_min_spacing: {:minutes, Duration.minutes(5), 1, 60, "m"},
    memory_max_gap: {:minutes, Duration.minutes(10), 1, 120, "m"},
    memory_confirmations: {:integer, 3, 1, 20, ""},
    memory_alert_cooldown: {:minutes, Duration.hours(1), 1, 1_440, "m"},
    swap_min_used: {:integer, 2_048, 128, 1_048_576, "M"},
    swap_min_growth: {:integer, 512, 64, 1_048_576, "M"},
    swap_min_spacing: {:minutes, Duration.minutes(5), 1, 60, "m"},
    swap_max_gap: {:minutes, Duration.minutes(10), 1, 120, "m"},
    swap_confirmations: {:integer, 3, 1, 20, ""},
    swap_alert_cooldown: {:minutes, Duration.hours(1), 1, 1_440, "m"},
    build_process_min_spacing: {:minutes, Duration.minutes(5), 1, 60, "m"},
    build_process_max_gap: {:minutes, Duration.minutes(10), 1, 120, "m"},
    build_process_confirmations: {:integer, 3, 1, 20, ""},
    build_process_alert_cooldown: {:minutes, Duration.hours(1), 1, 1_440, "m"},
    codex_min_idle: {:minutes, Duration.minutes(30), 1, 1_440, "m"},
    codex_min_spacing: {:minutes, Duration.minutes(5), 1, 60, "m"},
    codex_max_gap: {:minutes, Duration.minutes(10), 1, 120, "m"},
    codex_confirmations: {:integer, 3, 1, 20, ""},
    simulator_min_idle: {:minutes, Duration.minutes(15), 5, 1_440, "m"},
    playwright_confirmations: {:integer, 3, 2, 20, ""},
    unresponsive_confirmations: {:integer, 2, 2, 20, ""},
    unresponsive_restart_cooldown: {:minutes, Duration.hours(1), 15, 1_440, "m"},
    storage_cleanup_cooldown: {:minutes, Duration.hours(1), 15, 1_440, "m"},
    cleanclip_probe_interval: {:minutes, Duration.minutes(30), 1, 1_440, "m"},
    cleanclip_restart_cooldown: {:minutes, Duration.hours(1), 15, 1_440, "m"},
    cleanclip_failure_confirmations: {:integer, 3, 1, 20, ""},
    check_interval: {:integer, 5, 1, 60, "m"},
    cleanup_time: {:clock, {4, 0}, nil, nil, ""}
  }

  def defaults do
    Map.new(@schema, fn {key, {_type, default, _min, _max, _suffix}} -> {key, default} end)
  end

  def keys, do: @schema |> Map.keys() |> Enum.sort()
  def names, do: Enum.map(keys(), &name/1)
  def name(key), do: key |> Atom.to_string() |> String.replace("_", "-")

  def key(name) when is_binary(name) do
    Enum.find(keys(), &(name(&1) == name))
  end

  def read_all(home \\ Paths.home_dir()) do
    read_values(home)
    |> validate_relationships()
  end

  defp read_values(home, override_key \\ nil, override_value \\ nil) do
    Enum.reduce_while(keys(), {:ok, %{}}, fn key, {:ok, values} ->
      result = if key == override_key, do: {:ok, override_value}, else: read(key, home)

      case result do
        {:ok, value} -> {:cont, {:ok, Map.put(values, key, value)}}
        {:error, reason} -> {:halt, {:error, {name(key), reason}}}
      end
    end)
  end

  def read(key, home \\ Paths.home_dir()) when is_atom(key) do
    case Map.fetch(@schema, key) do
      :error ->
        {:error, :unknown_key}

      {:ok, {_type, default, _min, _max, _suffix}} ->
        case ConfigFile.get(name(key), home) do
          {:ok, text} -> parse(key, text)
          :missing -> read_path(key, default, home)
          error -> error
        end
    end
  end

  def set(name, text, home \\ Paths.home_dir())

  def set(name, text, home) when is_binary(name) and is_binary(text) do
    with key when not is_nil(key) <- key(name),
         {:ok, value} <- parse(key, text),
         {:ok, _policy} <- read_values(home, key, value) |> validate_relationships(),
         :ok <- ConfigFile.put(name(key), format(key, value), home) do
      {:ok, value}
    else
      nil -> {:error, :unknown_key}
      error -> error
    end
  end

  def set(_name, _text, _home), do: {:error, :invalid_value}

  def format(:cleanup_time, {hour, minute}) do
    :io_lib.format("~2..0B:~2..0B", [hour, minute]) |> IO.iodata_to_binary()
  end

  def format(key, value) do
    {type, _default, _min, _max, suffix} = Map.fetch!(@schema, key)
    number = if type == :minutes, do: div(value, Duration.minutes(1)), else: value
    "#{number}#{suffix}"
  end

  def description(:cleanup_time), do: "default 04:00, local clock 00:00..23:59"

  def description(key) do
    {_type, default, min, max, suffix} = Map.fetch!(@schema, key)
    "default #{format(key, default)}, range #{min}#{suffix}..#{max}#{suffix}"
  end

  defp validate_relationships({:error, _} = error), do: error

  defp validate_relationships({:ok, values}) do
    pairs = [
      {:memory_min_spacing, :memory_max_gap},
      {:swap_min_spacing, :swap_max_gap},
      {:build_process_min_spacing, :build_process_max_gap},
      {:codex_min_spacing, :codex_max_gap}
    ]

    cond do
      Enum.any?(pairs, fn {minimum, maximum} -> values[minimum] > values[maximum] end) ->
        {:error, :invalid_spacing_range}

      rem(60, values.check_interval) != 0 ->
        {:error, :invalid_check_interval}

      Enum.any?(pairs, fn {_minimum, maximum} ->
        Duration.minutes(values.check_interval) > values[maximum]
      end) ->
        {:error, :check_interval_exceeds_observation_gap}

      true ->
        {:ok, values}
    end
  end

  defp read_path(key, default, home) do
    path = path(key, home)

    case File.lstat(path) do
      {:error, :enoent} ->
        {:ok, default}

      {:ok, %{type: :regular, size: size}} when size <= @max_size ->
        case File.open(path, [:read, :binary], fn device -> IO.binread(device, @max_size + 1) end) do
          {:ok, text} when is_binary(text) and byte_size(text) <= @max_size -> parse(key, text)
          {:ok, _text} -> {:error, :config_too_large}
          error -> error
        end

      {:ok, %{type: :regular}} ->
        {:error, :config_too_large}

      {:ok, _stat} ->
        {:error, :invalid_config_file}

      error ->
        error
    end
  end

  defp path(key, home) do
    Path.join([home, "Library", "Application Support", "canaryd", "thresholds", name(key)])
  end

  defp parse(:cleanup_time, text) when is_binary(text) and byte_size(text) <= @max_size do
    case Regex.run(~r/\A([0-2][0-9]):([0-5][0-9])\z/, String.trim(text)) do
      [_, hour, minute] ->
        hour = String.to_integer(hour)

        if hour <= 23,
          do: {:ok, {hour, String.to_integer(minute)}},
          else: {:error, :invalid_value}

      _ ->
        {:error, :invalid_value}
    end
  end

  defp parse(key, text) when is_binary(text) and byte_size(text) <= @max_size do
    {type, _default, min, max, suffix} = Map.fetch!(@schema, key)
    value = String.trim(text)

    if String.ends_with?(value, suffix) do
      number = binary_part(value, 0, byte_size(value) - byte_size(suffix))

      parsed =
        case type do
          :decimal -> Float.parse(number)
          _ -> Integer.parse(number)
        end

      case parsed do
        {number, ""} when number >= min and number <= max ->
          {:ok, if(type == :minutes, do: Duration.minutes(number), else: number)}

        _ ->
          {:error, :invalid_value}
      end
    else
      {:error, :invalid_value}
    end
  end

  defp parse(_key, _text), do: {:error, :invalid_value}
end
