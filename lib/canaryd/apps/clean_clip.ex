defmodule Canaryd.Apps.CleanClip do
  @moduledoc """
  CleanClip health: L2 process liveness + L3 functional clipboard probe.

  The probe performs a reversible transaction: save the pasteboard, write a
  marker, wait, restore unchanged content, and check that a new file appeared
  in CleanClip's history directory.
  """

  alias Canaryd.Pasteboard

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

    case Pasteboard.probe(marker, @probe_wait_ms) do
      :ok ->
        probe_result(before, latest_mtime())

      {:error, reason} ->
        {:fail, reason}
    end
  end

  defp probe_result(_before, nil), do: {:fail, :history_dir_unreadable}
  defp probe_result(nil, _after_mtime), do: :ok

  defp probe_result(before, after_mtime) do
    if DateTime.compare(after_mtime, before) == :gt,
      do: :ok,
      else: {:fail, :no_new_history_item}
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
