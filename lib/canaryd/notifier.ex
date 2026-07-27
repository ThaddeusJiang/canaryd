defmodule Canaryd.Notifier do
  @moduledoc "macOS notifications and action dialogs. Used only when user attention is required."

  @action_timeout_sec 120
  @warning_timeout_sec 30

  @action_script """
  on run argv
    set processName to item 1 of argv

    try
      set response to display alert "Mac Health" message (processName & " is not responding." & return & return & "Close or Restart can force-stop this instance. macOS opens the service again when needed.") as warning buttons {"Ignore", "Close", "Restart"} default button "Restart" cancel button "Ignore" giving up after #{@action_timeout_sec}

      if gave up of response then
        return "ignore"
      end if

      set selectedButton to button returned of response

      if selectedButton is "Restart" then
        return "restart"
      else if selectedButton is "Close" then
        return "close"
      else
        return "ignore"
      end if
    on error number -128
      return "ignore"
    end try
  end run
  """

  @thermal_action_script """
  on run argv
    set processName to item 1 of argv
    set suspectSummary to item 2 of argv

    try
      set response to display alert "Mac temperature is high" message (processName & " is the leading CPU-related heat suspect." & return & return & suspectSummary & return & return & "CPU usage is correlation evidence. Close or Restart can discard unsaved data.") as warning buttons {"Ignore", "Close", "Restart"} default button "Ignore" cancel button "Ignore" giving up after #{@action_timeout_sec}

      if gave up of response then
        return "ignore"
      end if

      set selectedButton to button returned of response

      if selectedButton is "Restart" then
        return "restart"
      else if selectedButton is "Close" then
        return "close"
      else
        return "ignore"
      end if
    on error number -128
      return "ignore"
    end try
  end run
  """

  @temperature_warning_script """
  use framework "AppKit"
  use scripting additions

  on run argv
    set warningMessage to item 1 of argv
    current application's NSApplication's sharedApplication()'s activateIgnoringOtherApps:true

    try
      display alert "Mac temperature warning" message warningMessage as warning buttons {"Ignore"} default button "Ignore" giving up after #{@warning_timeout_sec}
      return "shown"
    on error number -128
      return "dismissed"
    end try
  end run
  """

  def notify(title, message) do
    script =
      ~s(display notification "#{escape(message)}" with title "#{escape(title)}" sound name "Glass")

    System.cmd("osascript", ["-e", script], stderr_to_stdout: true)
    :ok
  end

  @doc "Shows a visible, time-limited warning that does not depend on notification banners."
  def warn_temperature(message) do
    warn_temperature(message, &run_osascript/2)
  end

  @doc false
  def warn_temperature(message, runner) do
    case runner.("osascript", ["-e", @temperature_warning_script, message]) do
      {_output, 0} -> :ok
      {output, _status} -> {:error, {:dialog_failed, String.trim(output)}}
    end
  rescue
    _ -> {:error, :dialog_failed}
  end

  @doc "Shows a time-limited Close, Restart, or Ignore action dialog."
  def choose_app_action(process_name) do
    case System.cmd("osascript", ["-e", @action_script, process_name], stderr_to_stdout: true) do
      {output, 0} -> parse_app_action(output)
      {_output, _status} -> {:error, :dialog_failed}
    end
  rescue
    _ -> {:error, :dialog_failed}
  end

  @doc "Shows thermal suspects and asks the user to close, restart, or ignore one app."
  def choose_thermal_action(process_name, suspect_summary) do
    args = ["-e", @thermal_action_script, process_name, suspect_summary]

    case System.cmd("osascript", args, stderr_to_stdout: true) do
      {output, 0} -> parse_app_action(output)
      {_output, _status} -> {:error, :dialog_failed}
    end
  rescue
    _ -> {:error, :dialog_failed}
  end

  @doc false
  def parse_app_action(output) do
    case String.trim(output) do
      "restart" -> {:ok, :restart}
      "close" -> {:ok, :close}
      "ignore" -> {:ok, :ignore}
      _other -> {:error, :invalid_action}
    end
  end

  defp escape(s), do: String.replace(s, "\"", "\\\"")

  defp run_osascript(bin, args) do
    System.cmd(bin, args, stderr_to_stdout: true)
  end
end
