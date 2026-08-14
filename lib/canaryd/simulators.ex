defmodule Canaryd.Simulators do
  @moduledoc """
  Reads booted CoreSimulator devices and safely shuts down an exact device.

  The device list comes from `simctl`. The persisted CoreSimulator
  `lastUsedAt` value protects devices that were only recently booted. Active
  `xcodebuild` and `xctest` processes are treated as automation blockers.
  """

  alias Canaryd.Paths

  @udid_pattern ~r/[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}/
  @device_pattern ~r/^\s*(.*?)\s+\((#{@udid_pattern.source})\)\s+\(Booted\)\s*$/
  @runtime_pattern ~r/^--\s+(.+?)\s+--$/
  @automation_names MapSet.new(["xcodebuild", "xctest"])

  @doc "Returns every booted Simulator device in the default device set."
  def scan do
    case cmd("xcrun", ["simctl", "list", "devices", "booted"]) do
      {:ok, output} -> {:ok, parse_booted_devices(output)}
      {:error, _reason} = error -> error
    end
  end

  @doc false
  def parse_booted_devices(output), do: parse_booted_devices(output, &last_used_at/1)

  @doc false
  def parse_booted_devices(output, timestamp_reader) when is_function(timestamp_reader, 1) do
    {devices, _runtime} =
      output
      |> String.split("\n")
      |> Enum.reduce({[], nil}, fn line, {devices, runtime} ->
        cond do
          match = Regex.run(@runtime_pattern, line) ->
            [_, next_runtime] = match
            {devices, next_runtime}

          match = Regex.run(@device_pattern, line) ->
            [_, name, udid] = match

            device = %{
              udid: String.upcase(udid),
              name: String.trim(name),
              runtime: runtime,
              state: :booted,
              last_used_at: read_timestamp(timestamp_reader, String.upcase(udid))
            }

            {[device | devices], runtime}

          true ->
            {devices, runtime}
        end
      end)

    Enum.reverse(devices)
  end

  @doc "Returns current-user xcodebuild or xctest processes."
  def active_automation_processes do
    with {:ok, uid} <- current_uid(),
         {:ok, output} <- cmd("ps", ["-Ao", "pid=,uid=,comm="]) do
      {:ok, parse_automation_processes(output, uid)}
    end
  end

  @doc false
  def parse_automation_processes(output, current_uid) do
    output
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn row ->
      case String.split(String.trim(row), ~r/\s+/, parts: 3) do
        [pid_text, uid_text, command] ->
          with {pid, ""} when pid > 0 <- Integer.parse(pid_text),
               {uid, ""} <- Integer.parse(uid_text),
               true <- uid == current_uid,
               name <- command |> Path.basename() |> String.downcase(),
               true <- MapSet.member?(@automation_names, name) do
            [%{pid: pid, name: name}]
          else
            _ -> []
          end

        _ ->
          []
      end
    end)
  end

  @doc "Revalidates and shuts down one exact Simulator device without erasing it."
  def shutdown(device), do: shutdown(device, &scan/0, &cmd/2)

  @doc false
  def shutdown(
        %{udid: udid, last_used_at: expected_last_used_at},
        scan_devices,
        command_runner
      )
      when is_function(scan_devices, 0) and is_function(command_runner, 2) do
    if valid_udid?(udid) do
      with {:ok, devices} <- scan_devices.() do
        case Enum.find(devices, &(&1.udid == udid)) do
          nil ->
            :already_stopped

          %{last_used_at: ^expected_last_used_at} ->
            case command_runner.("xcrun", ["simctl", "shutdown", udid]) do
              {:ok, _output} -> :ok
              {:error, _reason} = error -> error
            end

          _device ->
            {:error, :device_activity_changed}
        end
      end
    else
      {:error, :invalid_udid}
    end
  end

  def shutdown(_device, _scan_devices, _command_runner), do: {:error, :invalid_device}

  @doc false
  def parse_last_used_at(output) do
    case DateTime.from_iso8601(String.trim(output)) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      _ -> {:error, :invalid_timestamp}
    end
  end

  defp last_used_at(udid) do
    plist = Path.join([Paths.simulator_devices_dir(), udid, "device.plist"])

    case cmd("plutil", ["-extract", "lastUsedAt", "raw", "-o", "-", plist]) do
      {:ok, output} -> parse_last_used_at(output)
      {:error, _reason} = error -> error
    end
  end

  defp read_timestamp(timestamp_reader, udid) do
    case timestamp_reader.(udid) do
      {:ok, %DateTime{} = datetime} -> datetime
      _ -> nil
    end
  end

  defp valid_udid?(udid) when is_binary(udid) do
    Regex.match?(~r/^#{@udid_pattern.source}$/, udid)
  end

  defp valid_udid?(_udid), do: false

  defp current_uid do
    with {:ok, output} <- cmd("id", ["-u"]),
         {uid, ""} <- Integer.parse(String.trim(output)) do
      {:ok, uid}
    else
      _ -> {:error, :unavailable}
    end
  end

  defp cmd(bin, args) do
    case System.cmd(bin, args, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, _status} -> {:error, String.trim(output)}
    end
  rescue
    _ -> {:error, :unavailable}
  end
end
