defmodule Canaryd.ConfigFile do
  @moduledoc """
  Shared per-user configuration file. Entries here override legacy per-key files.
  """

  alias Canaryd.{Paths, PolicyConfig}

  @max_size 16_384
  # Accept the retired schedule key in existing files so upgrades can still start.
  @extra_keys ["build-retention", "storage-threshold", "cleanup-time"]

  def path(home \\ Paths.home_dir()) do
    Path.join([home, "Library", "Application Support", "canaryd", "config.conf"])
  end

  def get(key, home \\ Paths.home_dir()) do
    with {:ok, {_text, entries}} <- load(home) do
      Map.fetch(entries, key)
      |> case do
        {:ok, value} -> {:ok, value}
        :error -> :missing
      end
    end
  end

  def put(key, value, home \\ Paths.home_dir()) when is_binary(key) and is_binary(value) do
    with true <- key in known_keys(),
         {:ok, {text, _entries}} <- load(home),
         updated = replace_entry(text, key, value),
         true <- byte_size(updated) <= @max_size,
         path = path(home),
         :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- replace_file(path, updated) do
      :ok
    else
      false -> {:error, :invalid_config_file}
      error -> error
    end
  end

  defp known_keys, do: PolicyConfig.names() ++ @extra_keys

  defp load(home) do
    path = path(home)

    case File.lstat(path) do
      {:error, :enoent} ->
        {:ok, {"", %{}}}

      {:ok, %{type: :regular, size: size}} when size <= @max_size ->
        case File.open(path, [:read, :binary], fn device -> IO.binread(device, @max_size + 1) end) do
          {:ok, :eof} ->
            {:ok, {"", %{}}}

          {:ok, text} when is_binary(text) and byte_size(text) <= @max_size ->
            with {:ok, entries} <- parse(text), do: {:ok, {text, entries}}

          {:ok, _text} ->
            {:error, :config_too_large}

          error ->
            error
        end

      {:ok, %{type: :regular}} ->
        {:error, :config_too_large}

      {:ok, _stat} ->
        {:error, :invalid_config_file}

      error ->
        error
    end
  end

  defp parse(text) do
    if String.valid?(text) do
      text
      |> String.split("\n")
      |> Enum.reduce_while({:ok, %{}}, fn line, {:ok, entries} ->
        line = String.trim(line)

        cond do
          line == "" or String.starts_with?(line, "#") ->
            {:cont, {:ok, entries}}

          true ->
            case String.split(line, "=", parts: 2) do
              [key, value] ->
                key = String.trim(key)

                if key in known_keys() and not Map.has_key?(entries, key) do
                  {:cont, {:ok, Map.put(entries, key, String.trim(value))}}
                else
                  {:halt, {:error, :invalid_config_file}}
                end

              _ ->
                {:halt, {:error, :invalid_config_file}}
            end
        end
      end)
    else
      {:error, :invalid_config_file}
    end
  end

  defp replace_entry("", key, value), do: "#{key}=#{value}\n"

  defp replace_entry(text, key, value) do
    lines = String.split(text, "\n", trim: false)

    if Enum.any?(lines, &entry?(&1, key)) do
      lines
      |> Enum.map(fn line -> if entry?(line, key), do: "#{key}=#{value}", else: line end)
      |> Enum.join("\n")
    else
      String.trim_trailing(text, "\n") <> "\n#{key}=#{value}\n"
    end
  end

  defp entry?(line, key) do
    case String.split(line, "=", parts: 2) do
      [name, _value] -> String.trim(name) == key
      _ -> false
    end
  end

  defp replace_file(path, contents) do
    temporary = "#{path}.#{System.pid()}.#{System.unique_integer([:positive])}.tmp"

    case File.open(temporary, [:write, :binary, :exclusive]) do
      {:ok, device} ->
        try do
          with :ok <- IO.binwrite(device, contents),
               :ok <- File.close(device) do
            File.rename(temporary, path)
          end
        after
          File.close(device)
          File.rm(temporary)
        end

      error ->
        error
    end
  end
end
