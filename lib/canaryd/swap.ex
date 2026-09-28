defmodule Canaryd.Swap do
  @moduledoc """
  Reads the macOS global swap usage counter.
  """

  @doc "Returns total, used, and free swap bytes."
  def sample(runner \\ &command/2) do
    case runner.("sysctl", ["-n", "vm.swapusage"]) do
      {output, 0} -> parse(output)
      _ -> {:error, :unavailable}
    end
  rescue
    _ -> {:error, :unavailable}
  end

  @doc false
  def parse(output) when is_binary(output) do
    with {:ok, total} <- value(output, "total"),
         {:ok, used} <- value(output, "used"),
         {:ok, free} <- value(output, "free") do
      {:ok, %{total_bytes: total, used_bytes: used, free_bytes: free}}
    end
  end

  def parse(_output), do: {:error, :invalid_output}

  @doc false
  def format_bytes(bytes) when is_integer(bytes) and bytes >= 0 do
    cond do
      bytes >= 1_024 * 1_024 * 1_024 -> "#{Float.round(bytes / 1_024 / 1_024 / 1_024, 1)} GB"
      bytes >= 1_024 * 1_024 -> "#{Float.round(bytes / 1_024 / 1_024, 1)} MB"
      bytes >= 1_024 -> "#{Float.round(bytes / 1_024, 1)} KB"
      true -> "#{bytes} B"
    end
  end

  defp value(output, name) do
    case Regex.run(~r/\b#{name}\s*=\s*([0-9]+(?:\.[0-9]+)?)\s*([KMGT]?)/i, output) do
      [_, number, unit] ->
        with {value, ""} <- Float.parse(number),
             {:ok, multiplier} <- multiplier(String.upcase(unit)) do
          {:ok, round(value * multiplier)}
        else
          _ -> {:error, :invalid_output}
        end

      _ ->
        {:error, :invalid_output}
    end
  end

  defp multiplier(""), do: {:ok, 1}
  defp multiplier("K"), do: {:ok, 1_024}
  defp multiplier("M"), do: {:ok, 1_024 * 1_024}
  defp multiplier("G"), do: {:ok, 1_024 * 1_024 * 1_024}
  defp multiplier("T"), do: {:ok, 1_024 * 1_024 * 1_024 * 1_024}
  defp multiplier(_unit), do: {:error, :invalid_unit}

  defp command("sysctl", args) do
    System.cmd("sysctl", args, stderr_to_stdout: true)
  end
end
