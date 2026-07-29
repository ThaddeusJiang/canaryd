defmodule Canaryd.Temperature do
  @moduledoc """
  Reads Apple Silicon CPU and GPU sensor temperatures from macmon.
  """

  alias Canaryd.Duration

  @supported_version "macmon 0.8.0"
  @sample_interval Duration.milliseconds(250)
  @sample_args ["pipe", "--samples", "3", "--interval", Integer.to_string(@sample_interval)]
  @known_paths ["/opt/homebrew/bin/macmon", "/usr/local/bin/macmon"]

  @doc "Returns average CPU and GPU sensor temperatures in degrees Celsius."
  def sample do
    case executable() do
      nil -> {:error, :macmon_not_found}
      path -> sample(&run/2, path)
    end
  end

  @doc false
  def sample(runner, path) do
    with {:ok, version_output} <- runner.(path, ["--version"]),
         :ok <- validate_version(version_output),
         {:ok, sample_output} <- runner.(path, @sample_args),
         {:ok, temperatures} <- parse_sample(sample_output) do
      {:ok, temperatures}
    end
  end

  @doc false
  def parse_sample(output) when is_binary(output) do
    with {:ok, cpu_temperature} <- parse_max_value(output, "cpu_temp_avg"),
         {:ok, gpu_temperature} <- parse_max_value(output, "gpu_temp_avg") do
      {:ok,
       %{
         cpu_temperature_c: Float.round(cpu_temperature, 1),
         gpu_temperature_c: Float.round(gpu_temperature, 1)
       }}
    else
      _ -> {:error, :invalid_output}
    end
  end

  defp executable do
    Enum.find(@known_paths, &File.exists?/1) || Elixir.System.find_executable("macmon")
  end

  defp validate_version(output) do
    version = String.trim(output)

    if version == @supported_version do
      :ok
    else
      {:error, {:unsupported_version, version}}
    end
  end

  defp parse_max_value(output, key) do
    pattern = ~r/"#{key}"\s*:\s*(-?\d+(?:\.\d+)?)/

    values =
      pattern
      |> Regex.scan(output, capture: :all_but_first)
      |> Enum.flat_map(fn
        [value] ->
          case Float.parse(value) do
            {number, ""} -> [number]
            _ -> []
          end
      end)

    case values do
      [] -> {:error, :missing_value}
      values -> {:ok, Enum.max(values)}
    end
  end

  defp run(path, args) do
    case Elixir.System.cmd(path, args, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, status} -> {:error, {:command_failed, status, String.trim(output)}}
    end
  rescue
    _ -> {:error, :command_unavailable}
  end
end
