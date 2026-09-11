defmodule Canaryd.PlaywrightBrowsers do
  @moduledoc """
  Finds leftover Playwright Chrome for Testing processes and terminates one PID.

  Classification uses a fixed Playwright-cache path. Command-line arguments are
  discarded before a process leaves the scanner. Helpers, crashpad, Google
  Chrome, the frontmost app, and other browsers are never actionable.
  """

  alias Canaryd.Duration

  @chrome_for_testing ~r{^/Users/[^/]+/Library/Caches/ms-playwright/chromium-[^/\s]+/chrome-mac-(?:arm64|x64)/Google Chrome for Testing\.app/Contents/MacOS/Google Chrome for Testing(?:\s.*)?$}
  @playwright_cli ~r{(?:^|/)playwright-cli(?:\s|$)}
  @playwright_bin ~r{(?:^|/)node_modules/\.bin/playwright(?:\s|$)}
  @playwright_node ~r{(?:^|/)node_modules/playwright(?:-core)?/cli\.js(?:\s|$)}
  @maximum_candidates 250
  @termination_attempts 10
  @termination_poll Duration.milliseconds(100)
  @frontmost_script """
  ObjC.import("AppKit")
  String($.NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier)
  """

  @doc "Returns leftover Playwright Chrome for Testing processes for this user."
  def scan do
    with {:ok, processes} <- list_browsers(),
         {:ok, frontmost} <- frontmost_pid() do
      {:ok, exclude_frontmost(processes, frontmost)}
    end
  end

  @doc false
  def parse_processes(output, current_uid) do
    output
    |> String.split("\n", trim: true)
    |> Enum.flat_map(&parse_process_row(&1, current_uid))
  end

  @doc "Returns current-user Playwright runner processes."
  def active_automation_processes do
    with {:ok, uid} <- current_uid(),
         {:ok, output} <- cmd("ps", ["-Ao", "pid=,uid=,command="]) do
      {:ok, parse_automation_processes(output, uid)}
    end
  end

  @doc false
  def parse_automation_processes(output, current_uid) do
    output
    |> String.split("\n", trim: true)
    |> Enum.flat_map(&parse_automation_row(&1, current_uid))
  end

  @doc false
  def exclude_frontmost(browsers, frontmost_pid)
      when is_list(browsers) and is_integer(frontmost_pid) and frontmost_pid > 0 do
    Enum.reject(browsers, &(&1.pid == frontmost_pid))
  end

  def exclude_frontmost(browsers, _frontmost_pid), do: browsers

  @doc "Revalidates a browser identity and requests graceful termination."
  def terminate(process) do
    with {:ok, frontmost} <- frontmost_pid() do
      terminate(process, &list_browsers/0, &cmd/2, &Process.sleep/1, frontmost)
    end
  end

  @doc false
  def terminate(
        %{id: id, pid: pid},
        scanner,
        runner,
        sleeper,
        frontmost_pid
      )
      when is_tuple(id) and is_integer(pid) and pid > 0 and is_function(scanner, 0) and
             is_function(runner, 2) and is_function(sleeper, 1) and is_integer(frontmost_pid) do
    with {:ok, processes} <- scanner.() do
      case Enum.find(processes, &(&1.pid == pid)) do
        nil ->
          :already_stopped

        %{id: ^id} when pid == frontmost_pid ->
          {:error, :browser_became_frontmost}

        %{id: ^id} ->
          request_termination(pid, runner, sleeper)

        _replacement ->
          {:error, :process_identity_changed}
      end
    end
  end

  def terminate(_process, _scanner, _runner, _sleeper, _frontmost_pid),
    do: {:error, :invalid_process}

  defp list_browsers do
    with {:ok, uid} <- current_uid(),
         {:ok, output} <- cmd("ps", ["-Ao", "pid=,ppid=,uid=,lstart=,command="]) do
      processes = parse_processes(output, uid)

      if length(processes) <= @maximum_candidates do
        {:ok, processes}
      else
        {:error, :too_many_candidates}
      end
    end
  end

  defp frontmost_pid do
    with {:ok, output} <- cmd("osascript", ["-l", "JavaScript", "-e", @frontmost_script]),
         {pid, ""} when pid > 0 <- Integer.parse(String.trim(output)) do
      {:ok, pid}
    else
      _ -> {:error, :unavailable}
    end
  end

  defp parse_process_row(row, current_uid) do
    case String.split(String.trim(row), ~r/\s+/, parts: 9) do
      [pid_text, ppid_text, uid_text, weekday, month, day, time, year, command] ->
        with {pid, ""} when pid > 0 <- Integer.parse(pid_text),
             {ppid, ""} when ppid >= 0 <- Integer.parse(ppid_text),
             {uid, ""} <- Integer.parse(uid_text),
             true <- uid == current_uid,
             true <- chrome_for_testing?(command) do
          started_at = Enum.join([weekday, month, day, time, year], " ")

          [
            %{
              id: {:chrome_for_testing, pid, started_at},
              kind: :chrome_for_testing,
              pid: pid,
              ppid: ppid,
              started_at: started_at,
              name: "Chrome for Testing"
            }
          ]
        else
          _ -> []
        end

      _ ->
        []
    end
  end

  defp parse_automation_row(row, current_uid) do
    case String.split(String.trim(row), ~r/\s+/, parts: 3) do
      [pid_text, uid_text, command] ->
        with {pid, ""} when pid > 0 <- Integer.parse(pid_text),
             {uid, ""} <- Integer.parse(uid_text),
             true <- uid == current_uid,
             true <- playwright_runner?(command) do
          [%{pid: pid, name: "playwright"}]
        else
          _ -> []
        end

      _ ->
        []
    end
  end

  defp chrome_for_testing?(command), do: Regex.match?(@chrome_for_testing, command)

  defp playwright_runner?(command) do
    Regex.match?(@playwright_cli, command) or Regex.match?(@playwright_bin, command) or
      Regex.match?(@playwright_node, command)
  end

  defp request_termination(pid, runner, sleeper) do
    case runner.("kill", ["-TERM", Integer.to_string(pid)]) do
      {:ok, _output} -> wait_for_stop(pid, @termination_attempts, runner, sleeper)
      {:error, reason} -> {:error, {:termination_failed, reason}}
    end
  end

  defp wait_for_stop(_pid, 0, _runner, _sleeper), do: {:error, :process_did_not_stop}

  defp wait_for_stop(pid, attempts, runner, sleeper) do
    case runner.("kill", ["-0", Integer.to_string(pid)]) do
      {:ok, _output} ->
        sleeper.(@termination_poll)
        wait_for_stop(pid, attempts - 1, runner, sleeper)

      {:error, _reason} ->
        :ok
    end
  end

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
