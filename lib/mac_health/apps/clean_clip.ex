defmodule MacHealth.Apps.CleanClip do
  @moduledoc """
  CleanClip health: L2 process liveness + L3 functional clipboard probe.

  The probe performs a synthetic transaction: write a marker string to the
  pasteboard via pbcopy, wait, then check that a new file appeared in
  CleanClip's history directory.
  """

  @app_name "CleanClip"
  @process_pattern "/Applications/CleanClip.app/Contents/MacOS/CleanClip"
  @history_dir Path.expand(
                 "~/Library/Application Support/com.antiless.cleanclip.mac/PrivateData/HistoryItemContents"
               )
  @probe_wait_ms 4_000

  def process_alive? do
    case System.cmd("pgrep", ["-f", @process_pattern], stderr_to_stdout: true) do
      {out, 0} -> String.trim(out) != ""
      _ -> false
    end
  end

  def start do
    System.cmd("open", ["-a", @app_name], stderr_to_stdout: true)
    Process.sleep(5_000)
    process_alive?()
  end

  def restart do
    System.cmd("pkill", ["-f", @process_pattern], stderr_to_stdout: true)
    Process.sleep(2_000)
    start()
  end

  @doc """
  Run the functional probe. Returns :ok | {:fail, reason}.
  Assumes the process is already running.
  """
  def probe do
    before = latest_mtime()
    marker = "mac-health-probe-#{System.unique_integer([:positive])}"

    {_, 0} = System.cmd("osascript", ["-e", "set the clipboard to \"#{marker}\""], stderr_to_stdout: true)
    Process.sleep(@probe_wait_ms)

    after_mtime = latest_mtime()

    cond do
      is_nil(after_mtime) ->
        {:fail, :history_dir_unreadable}

      is_nil(before) or DateTime.compare(after_mtime, before) == :gt ->
        :ok

      true ->
        {:fail, :no_new_history_item}
    end
  end

  defp latest_mtime do
    with true <- File.dir?(@history_dir),
         {:ok, files} <- File.ls(@history_dir) do
      files
      |> Enum.take(5_000)
      |> Enum.map(&Path.join(@history_dir, &1))
      |> Enum.flat_map(fn path ->
        case File.stat(path, time: :posix) do
          {:ok, %{mtime: mtime, type: :regular}} -> [mtime]
          _ -> []
        end
      end)
      |> Enum.max(fn -> nil end)
      |> case do
        nil -> nil
        posix -> DateTime.from_unix!(posix)
      end
    else
      _ -> nil
    end
  end
end
