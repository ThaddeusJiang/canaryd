defmodule Canaryd.BuildCleanupConfig do
  @moduledoc false

  alias Canaryd.{ConfigFile, Duration, Paths}

  @max_size 64
  @max_value 87_600

  def default_retention, do: Duration.hours(1)

  def read(home \\ Paths.home_dir()) do
    case ConfigFile.get("build-retention", home) do
      {:ok, value} -> parse(value)
      :missing -> read_legacy(home)
      error -> error
    end
  end

  def set(value, home \\ Paths.home_dir()) do
    with {:ok, retention} <- parse(value),
         :ok <- ConfigFile.put("build-retention", format(retention), home) do
      {:ok, retention}
    end
  end

  def format(retention), do: "#{div(retention, Duration.hours(1))}h"

  defp config_path(home) do
    Path.join([home, "Library", "Application Support", "canaryd", "build-cleanup-retention"])
  end

  defp read_legacy(home) do
    path = config_path(home)

    case File.lstat(path) do
      {:error, :enoent} -> {:ok, default_retention()}
      {:ok, %{type: :regular}} -> read_file(path)
      {:ok, _stat} -> {:error, :invalid_config_file}
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_file(path) do
    case File.open(path, [:read, :binary], &read_bounded/1) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_bounded(device) do
    with :ok <- check_size(device),
         {:ok, value} <- :file.read(device, @max_size),
         :ok <- check_size(device) do
      parse(value)
    else
      :eof -> {:error, :invalid_retention}
      {:error, reason} -> {:error, reason}
    end
  end

  defp check_size(device) do
    with {:ok, record} <- :file.read_file_info(device) do
      case File.Stat.from_record(record) do
        %{type: :regular, size: size} when size <= @max_size -> :ok
        %{size: size} when size > @max_size -> {:error, :config_too_large}
        _stat -> {:error, :invalid_config_file}
      end
    end
  end

  @doc false
  def parse(value) when is_binary(value) and byte_size(value) <= @max_size do
    case Regex.run(~r/\A([0-9]+)h?\z/, String.trim(value)) do
      [_, number] ->
        case String.to_integer(number) do
          value when value in 1..@max_value -> {:ok, Duration.hours(value)}
          _value -> {:error, :invalid_retention}
        end

      _match ->
        {:error, :invalid_retention}
    end
  end

  def parse(_value), do: {:error, :invalid_retention}
end
