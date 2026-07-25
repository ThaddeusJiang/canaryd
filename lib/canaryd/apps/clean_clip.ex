defmodule Canaryd.Apps.CleanClip do
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
    marker = "canaryd-probe-#{System.unique_integer([:positive])}"

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

  # The directory's own mtime bumps whenever CleanClip adds a history item.
  # (47k+ files inside; stat-ing each file would be slow and sampling is flaky.)
  defp latest_mtime do
    case File.stat(@history_dir, time: :posix) do
      {:ok, %{mtime: mtime}} -> DateTime.from_unix!(mtime)
      _ -> nil
    end
  end
end
