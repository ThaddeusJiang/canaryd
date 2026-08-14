defmodule Canaryd.Notifier do
  @moduledoc "macOS notifications. Used only when user attention is required."

  alias Canaryd.{Duration, NotificationHelper}

  def notify(title, message) do
    notify(title, message, &run_notification_helper/2)
  end

  @doc false
  def notify(title, message, runner) do
    send_notification(title, message, runner)
  end

  @doc "Sends a temperature warning that stays in Notification Center until dismissal."
  def warn_temperature(message) do
    warn_temperature(message, &run_notification_helper/2)
  end

  @doc false
  def warn_temperature(message, runner) do
    send_notification("Mac temperature warning", message, runner)
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

  defp send_notification(title, message, runner) do
    args = ["notify", title, message, Integer.to_string(Duration.seconds(30))]

    case runner.(NotificationHelper.executable_path(), args) do
      {_output, 0} -> :ok
      {output, _status} -> {:error, {:notification_failed, String.trim(output)}}
    end
  rescue
    _ -> {:error, :notification_failed}
  end

  defp choose_action(title, message, runner) do
    args = ["action", title, message, Integer.to_string(Duration.minutes(2))]

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
