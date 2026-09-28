defmodule Canaryd.Disk do
  @moduledoc """
  Reads APFS/Data-volume usage and macOS global swap usage.

  Disk pressure is a trigger for the existing fail-closed build cleanup. It is
  not permission to remove arbitrary files.
  """

  @data_volume "/System/Volumes/Data"
  @bytes_per_kib 1_024

  @doc "Returns usage for the macOS Data volume."
  def sample(runner \\ &command/2) do
    case runner.("df", ["-Pk", @data_volume]) do
      {output, 0} -> parse_df(output)
      _ -> {:error, :unavailable}
    end
  rescue
    _ -> {:error, :unavailable}
  end

  @doc "Returns true when the volume needs the guarded cleanup path."
  def pressure?(usage, threshold_bytes \\ Canaryd.DiskPressureConfig.default_bytes())

  def pressure?(%{available_bytes: available_bytes}, threshold_bytes)
      when is_integer(available_bytes) and is_integer(threshold_bytes) and threshold_bytes > 0 do
    available_bytes < threshold_bytes
  end

  def pressure?(_usage, _threshold_bytes), do: false

  @doc false
  def format_bytes(bytes) when is_integer(bytes) and bytes >= 0 do
    cond do
      bytes >= 1_024 * 1_024 * 1_024 -> "#{Float.round(bytes / 1_024 / 1_024 / 1_024, 1)} GB"
      bytes >= 1_024 * 1_024 -> "#{Float.round(bytes / 1_024 / 1_024, 1)} MB"
      bytes >= 1_024 -> "#{Float.round(bytes / 1_024, 1)} KB"
      true -> "#{bytes} B"
    end
  end

  @doc false
  def parse_df(output) when is_binary(output) do
    case output |> String.split(~r/\r?\n/, trim: true) |> List.last() do
      nil -> {:error, :invalid_output}
      row -> parse_df_row(row)
    end
  end

  def parse_df(_output), do: {:error, :invalid_output}

  defp parse_df_row(row) do
    case String.split(row, ~r/\s+/, trim: true) do
      [_filesystem, blocks, used, available, capacity | mount] when mount != [] ->
        with {blocks, ""} <- Integer.parse(blocks),
             {used, ""} <- Integer.parse(used),
             {available, ""} <- Integer.parse(available),
             {used_percent, "%"} <- Integer.parse(capacity),
             true <- blocks >= 0 and used >= 0 and available >= 0 and used_percent in 0..100 do
          {:ok,
           %{
             mount: Enum.join(mount, " "),
             total_bytes: blocks * @bytes_per_kib,
             used_bytes: used * @bytes_per_kib,
             available_bytes: available * @bytes_per_kib,
             used_percent: used_percent
           }}
        else
          _ -> {:error, :invalid_output}
        end

      _ ->
        {:error, :invalid_output}
    end
  end

  defp command("df", args) do
    System.cmd("df", args, stderr_to_stdout: true)
  end
end
