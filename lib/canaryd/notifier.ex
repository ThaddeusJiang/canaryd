defmodule Canaryd.Notifier do
  @moduledoc "macOS Notification Center. Used ONLY when user attention is required."

  def notify(title, message) do
    script = ~s(display notification "#{escape(message)}" with title "#{escape(title)}" sound name "Glass")
    System.cmd("osascript", ["-e", script], stderr_to_stdout: true)
    :ok
  end

  defp escape(s), do: String.replace(s, "\"", "\\\"")
end
