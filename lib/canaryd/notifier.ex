defmodule Canaryd.Notifier do
  @moduledoc "macOS notifications. Used only when user attention is required."

  alias Canaryd.NotificationHelper

  @action_timeout_sec 120
  @warning_timeout_sec 30

  def notify(title, message) do
    script =
      ~s(display notification "#{escape(message)}" with title "#{escape(title)}" sound name "Glass")

    System.cmd("osascript", ["-e", script], stderr_to_stdout: true)
    :ok
  end

  @doc "Sends a temperature warning that stays in Notification Center until dismissal."
  def warn_temperature(message) do
    warn_temperature(message, &run_notification_helper/2)
  end

  @doc false
  def warn_temperature(message, runner) do
    args = ["notify", "Mac temperature warning", message, Integer.to_string(@warning_timeout_sec)]

    case runner.(NotificationHelper.executable_path(), args) do
      {_output, 0} -> :ok
      {output, _status} -> {:error, {:notification_failed, String.trim(output)}}
    end
  rescue
    _ -> {:error, :notification_failed}
  end

  @doc "Sends a time-limited notification with Close and Restart actions."
  def choose_app_action(process_name) do
    choose_app_action(process_name, &run_notification_helper/2)
  end

  @doc false
  def choose_app_action(process_name, runner) do
    message =
      "#{process_name} is not responding. Close or Restart can force-stop this instance. " <>
        "macOS opens the service again when needed."

    choose_action("Mac Health", message, runner)
  end

  @doc "Sends thermal details in a notification with Close and Restart actions."
  def choose_thermal_action(process_name, suspect_summary) do
    choose_thermal_action(process_name, suspect_summary, &run_notification_helper/2)
  end

  @doc false
  def choose_thermal_action(process_name, suspect_summary, runner) do
    message =
      "#{process_name} is the leading CPU-related heat suspect.\n#{suspect_summary}\n" <>
        "CPU usage is correlation evidence. Close or Restart can discard unsaved data."

    choose_action("Mac temperature is high", message, runner)
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

  defp choose_action(title, message, runner) do
    args = ["action", title, message, Integer.to_string(@action_timeout_sec)]

    case runner.(NotificationHelper.executable_path(), args) do
      {output, 0} -> parse_app_action(output)
      {_output, _status} -> {:error, :notification_failed}
    end
  rescue
    _ -> {:error, :notification_failed}
  end

  defp run_notification_helper(bin, args) do
    System.cmd(bin, args, stderr_to_stdout: true)
  end
end
