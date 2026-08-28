alias Canaryd.NotificationHelper

window_number_script = """
import CoreGraphics
import Foundation

let windows = CGWindowListCopyWindowInfo(
    [.optionOnScreenOnly],
    kCGNullWindowID
)! as! [[String: Any]]

var selectedNumber: Int?
var selectedLayer = Int.max

for window in windows {
    guard window[kCGWindowOwnerName as String] as? String == "Notification Center",
          let number = window[kCGWindowNumber as String] as? Int,
          let layer = window[kCGWindowLayer as String] as? Int else {
        continue
    }

    if layer < selectedLayer {
        selectedNumber = number
        selectedLayer = layer
    }
}

if let selectedNumber {
    print(selectedNumber)
    exit(0)
}

exit(1)
"""

reveal_actions_script = """
import CoreGraphics

let displayBounds = CGDisplayBounds(CGMainDisplayID())
let point = CGPoint(x: displayBounds.maxX - 70, y: 130)
CGWarpMouseCursorPosition(point)

let move = CGEvent(
    mouseEventSource: nil,
    mouseType: .mouseMoved,
    mouseCursorPosition: point,
    mouseButton: .left
)
move?.post(tap: .cghidEventTap)
usleep(300_000)

let down = CGEvent(
    mouseEventSource: nil,
    mouseType: .leftMouseDown,
    mouseCursorPosition: point,
    mouseButton: .left
)
let up = CGEvent(
    mouseEventSource: nil,
    mouseType: .leftMouseUp,
    mouseCursorPosition: point,
    mouseButton: .left
)
down?.post(tap: .cghidEventTap)
up?.post(tap: .cghidEventTap)
"""

notifications = [
  %{
    file: "thermal-warning.png",
    mode: "notify",
    title: "Mac temperature warning",
    body:
      "CPU 74.7°C; GPU 74.5°C; battery 40.5°C\n\n" <>
        "Suspects: Xcode (PID 4242, CPU 187.3%), Simulator (PID 4243, CPU 42.8%)"
  },
  %{
    file: "thermal-warning-fallback.png",
    mode: "notify",
    title: "Mac temperature warning",
    body:
      "CPU 74.7°C; GPU 74.5°C; battery 40.5°C; " <>
        "Suspects: Xcode (PID 4242, CPU 187.3%), Simulator (PID 4243, CPU 42.8%)"
  },
  %{
    file: "thermal-action.png",
    mode: "action",
    title: "Mac temperature is high",
    body:
      "Xcode is the leading CPU-related heat suspect.\n" <>
        "CPU 74.7°C; GPU 74.5°C; battery 40.5°C\n" <>
        "Xcode (PID 4242, CPU 187.3%), Simulator (PID 4243, CPU 42.8%)\n" <>
        "CPU usage is correlation evidence. Close or Restart can discard unsaved data."
  },
  %{
    file: "thermal-action-failed.png",
    mode: "notify",
    title: "Mac Health",
    body: "The selected thermal action for Xcode failed."
  },
  %{
    file: "idle-memory-closed.png",
    mode: "notify",
    title: "Mac Health",
    body: "Closed idle Xcode after it used 2048 MB of memory."
  },
  %{
    file: "idle-memory-close-failed.png",
    mode: "notify",
    title: "Mac Health",
    body: "Could not close idle high-memory app Xcode."
  },
  %{
    file: "simulators-shut-down.png",
    mode: "notify",
    title: "Mac Health",
    body: "Shut down idle Simulators: iPhone 16 Pro, iPad Pro 13-inch."
  },
  %{
    file: "simulators-shutdown-failed.png",
    mode: "notify",
    title: "Mac Health",
    body: "Could not shut down idle Simulators: iPhone 16 Pro."
  },
  %{
    file: "app-restart-failed.png",
    mode: "notify",
    title: "Mac Health",
    body: "CursorUIViewService was unresponsive and could not restart."
  },
  %{
    file: "app-still-unresponsive.png",
    mode: "notify",
    title: "Mac Health",
    body: "CursorUIViewService is still unresponsive after an automatic restart."
  },
  %{
    file: "system-degraded.png",
    mode: "notify",
    title: "Mac Health",
    body: "System degraded: CPU 74.7°C; memory free 8%"
  },
  %{
    file: "cleanclip-restart-failed.png",
    mode: "notify",
    title: "Mac Health",
    body: "CleanClip unresponsive; auto-restart failed. Please check manually."
  }
]

requested_files = MapSet.new(System.argv())

notifications =
  if MapSet.size(requested_files) == 0 do
    notifications
  else
    selected = Enum.filter(notifications, &MapSet.member?(requested_files, &1.file))

    if length(selected) != MapSet.size(requested_files) do
      known_files = notifications |> Enum.map(& &1.file) |> Enum.join(", ")
      raise "unknown screenshot file; expected one of: #{known_files}"
    end

    selected
  end

find_window_number = fn find_window_number, attempts ->
  case System.cmd("/usr/bin/swift", ["-e", window_number_script], stderr_to_stdout: true) do
    {output, 0} ->
      String.trim(output)

    {_output, _status} when attempts > 0 ->
      Process.sleep(100)
      find_window_number.(find_window_number, attempts - 1)

    {output, status} ->
      raise "Notification Center window not found (#{status}): #{String.trim(output)}"
  end
end

case NotificationHelper.ensure_installed() do
  :ok -> :ok
  {:error, reason} -> raise "notification helper install failed: #{inspect(reason)}"
end

helper = NotificationHelper.executable_path()
output_dir = Path.expand("../docs/assets/notifications", __DIR__)
File.mkdir_p!(output_dir)

Enum.each(notifications, fn notification ->
  System.cmd("/usr/bin/killall", ["NotificationCenter"], stderr_to_stdout: true)
  Process.sleep(1_500)

  timeout = if notification.mode == "action", do: "4000", else: "30000"
  args = [notification.mode, notification.title, notification.body, timeout]

  helper_task =
    if notification.mode == "action" do
      Task.async(fn -> System.cmd(helper, args, stderr_to_stdout: true) end)
    else
      case System.cmd(helper, args, stderr_to_stdout: true) do
        {_output, 0} -> nil
        {output, status} -> raise "notification failed (#{status}): #{String.trim(output)}"
      end
    end

  Process.sleep(350)

  if notification.mode == "action" do
    case System.cmd("/usr/bin/swift", ["-e", reveal_actions_script], stderr_to_stdout: true) do
      {_output, 0} -> Process.sleep(350)
      {output, status} -> raise "could not reveal actions (#{status}): #{String.trim(output)}"
    end
  end

  window_number = find_window_number.(find_window_number, 15)
  output_path = Path.join(output_dir, notification.file)

  case System.cmd("/usr/sbin/screencapture", ["-x", "-l", window_number, output_path],
         stderr_to_stdout: true
       ) do
    {_output, 0} -> IO.puts("captured #{Path.relative_to_cwd(output_path)}")
    {output, status} -> raise "screenshot failed (#{status}): #{String.trim(output)}"
  end

  if helper_task do
    case Task.await(helper_task, 6_000) do
      {_output, 0} -> :ok
      {output, status} -> raise "action notification failed (#{status}): #{String.trim(output)}"
    end
  end
end)

System.cmd("/usr/bin/killall", ["NotificationCenter"], stderr_to_stdout: true)
