defmodule Canaryd.DiskPressureConfig do
  @moduledoc false

  alias Canaryd.{ConfigFile, Paths}

  @gib 1_024 * 1_024 * 1_024
  @default_gib 10
  @max_gib 1_024
  @max_size 64

  def default_bytes, do: @default_gib * @gib

  def read(home \\ Paths.home_dir()) do
    case ConfigFile.get("storage-threshold", home) do
      {:ok, value} -> parse(value)
      :missing -> read_legacy(home)
      error -> error
    end
  end

  def set(value, home \\ Paths.home_dir()) do
    with {:ok, bytes} <- parse(value),
         :ok <- ConfigFile.put("storage-threshold", format(bytes), home) do
      {:ok, bytes}
    end
  end

  def format(bytes), do: "#{div(bytes, @gib)}G"

  defp config_path(home) do
    Path.join([home, "Library", "Application Support", "canaryd", "storage-threshold"])
  end

  defp read_legacy(home) do
    path = config_path(home)

    case File.lstat(path) do
      {:error, :enoent} -> {:ok, default_bytes()}
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
      :eof -> {:error, :invalid_threshold}
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

  defp parse(value) when is_binary(value) and byte_size(value) <= @max_size do
    case Regex.run(~r/\A([0-9]+)G\z/, String.trim(value)) do
      [_, number] ->
        case String.to_integer(number) do
          gib when gib in 1..@max_gib -> {:ok, gib * @gib}
          _value -> {:error, :invalid_threshold}
        end

      _match ->
        {:error, :invalid_threshold}
    end
  end

  defp parse(_value), do: {:error, :invalid_threshold}
end
