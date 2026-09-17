defmodule Canaryd.Config do
  @moduledoc "Validated CLI settings: flags, environment, saved retention, then defaults."
  alias Canaryd.{BuildCleanupConfig, Duration, Paths}

  @switches [check_interval: :string, cleanup_at: :string, build_retention: :string]
  def switches, do: @switches

  def defaults,
    do: %{
      check_interval: Duration.minutes(5),
      cleanup_at: %{hour: 4, minute: 0},
      build_retention: BuildCleanupConfig.default_retention(),
      retention_override: false
    }

  def resolve(overrides \\ [], options \\ []) do
    with {:ok, interval} <-
           value(
             :check_interval,
             overrides,
             options,
             format(:check_interval, defaults().check_interval),
             &parse_interval/1
           ),
         {:ok, calendar} <-
           value(
             :cleanup_at,
             overrides,
             options,
             format(:cleanup_at, defaults().cleanup_at),
             &parse_calendar/1
           ),
         {:ok, retention} <- retention(overrides, options) do
      {:ok,
       %{
         check_interval: interval,
         cleanup_at: calendar,
         build_retention: retention,
         retention_override: not is_nil(selected(:build_retention, overrides, options))
       }}
    end
  end

  def retention(overrides \\ [], options \\ []) do
    case selected(:build_retention, overrides, options) do
      nil -> BuildCleanupConfig.read(Keyword.get(options, :home, Paths.home_dir()))
      raw -> parse(:build_retention, raw, &BuildCleanupConfig.parse/1)
    end
  end

  defp value(key, overrides, options, default, parser),
    do: parse(key, selected(key, overrides, options) || default, parser)

  defp selected(key, overrides, options) do
    env = Keyword.get_lazy(options, :env, &System.get_env/0)
    Keyword.get(overrides, key, Map.get(env, "CANARYD_" <> String.upcase(to_string(key))))
  end

  defp parse(key, raw, parser) do
    case parser.(raw) do
      {:ok, value} ->
        {:ok, value}

      _ ->
        {:error,
         "invalid --#{String.replace(to_string(key), "_", "-")} / CANARYD_#{String.upcase(to_string(key))}"}
    end
  end

  defp parse_interval(raw) when is_binary(raw) and byte_size(raw) <= 16 do
    with [_, digits, unit] <- Regex.run(~r/\A([0-9]+)(s|m|h)\z/, raw),
         number <- String.to_integer(digits),
         value <-
           number *
             %{"s" => Duration.seconds(1), "m" => Duration.minutes(1), "h" => Duration.hours(1)}[
               unit
             ],
         true <- value >= Duration.seconds(1) and value <= Duration.days(1) do
      {:ok, value}
    else
      _ -> {:error, :invalid_interval}
    end
  end

  defp parse_interval(_), do: {:error, :invalid_interval}

  defp parse_calendar(raw) when is_binary(raw) and byte_size(raw) == 5 do
    with [_, hour, minute] <- Regex.run(~r/\A([0-9]{2}):([0-9]{2})\z/, raw),
         hour <- String.to_integer(hour),
         minute <- String.to_integer(minute),
         true <- hour < 24 and minute < 60 do
      {:ok, %{hour: hour, minute: minute}}
    else
      _ -> {:error, :invalid_time}
    end
  end

  defp parse_calendar(_), do: {:error, :invalid_time}

  def format(:check_interval, value), do: "#{Duration.to_external(value, :second)}s"
  def format(:build_retention, value), do: BuildCleanupConfig.format(value)

  def format(:cleanup_at, %{hour: h, minute: m}),
    do:
      String.pad_leading(to_string(h), 2, "0") <> ":" <> String.pad_leading(to_string(m), 2, "0")
end
