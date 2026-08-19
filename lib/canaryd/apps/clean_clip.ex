defmodule Canaryd.Apps.CleanClip do
  @moduledoc """
  CleanClip health: L2 process liveness + L3 functional clipboard probe.

  The probe reads the latest real CleanClip history item, writes the same data
  back to the pasteboard, and checks that CleanClip increments its copy count.
  """

  alias Canaryd.{CleanClipHistory, Duration, Pasteboard, Paths}

  @app_name "CleanClip"
  @process_pattern "/Applications/CleanClip.app/Contents/MacOS/CleanClip"
  def process_alive? do
    case System.cmd("pgrep", ["-f", @process_pattern], stderr_to_stdout: true) do
      {out, 0} -> String.trim(out) != ""
      _ -> false
    end
  end

  @doc false
  def history_dir, do: Paths.clean_clip_history_dir()

  def start do
    System.cmd("open", ["-a", @app_name], stderr_to_stdout: true)
    Process.sleep(Duration.seconds(5))
    process_alive?()
  end

  def restart do
    System.cmd("pkill", ["-f", @process_pattern], stderr_to_stdout: true)
    Process.sleep(Duration.seconds(2))
    start()
  end

  @doc """
  Run the functional probe. Returns :ok | {:fail, reason}.
  Assumes the process is already running.
  """
  def probe(options \\ []) do
    history_reader = Keyword.get(options, :history_reader, &CleanClipHistory.latest/0)
    pasteboard_replayer = Keyword.get(options, :pasteboard_replayer, &Pasteboard.replay/2)

    duplicate_reader =
      Keyword.get(options, :duplicate_reader, &CleanClipHistory.duplicate_recorded?/1)

    with {:ok, item} <- history_reader.(),
         :ok <- pasteboard_replayer.(item.contents, Duration.seconds(4)) do
      duplicate_result(duplicate_reader.(item))
    else
      {:error, reason} -> {:fail, reason}
    end
  end

  defp duplicate_result({:ok, true}), do: :ok
  defp duplicate_result({:ok, false}), do: {:fail, :no_duplicate_history_item}
  defp duplicate_result({:error, reason}), do: {:fail, reason}
end
