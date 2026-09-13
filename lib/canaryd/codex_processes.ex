defmodule Canaryd.CodexProcesses do
  @moduledoc """
  Finds stale-prone Codex screen-control helpers and terminates an exact process.

  Classification uses fixed command signatures, but command-line arguments are
  discarded before a process leaves the scanner. The long-lived CUA Driver
  service and unrelated Node processes are never actionable.
  """

  alias Canaryd.Duration

  @computer_use_service ~r{^/Users/[^/]+/\.codex/computer-use/Codex Computer Use\.app/Contents/MacOS/SkyComputerUseService$}
  @computer_history_mcp ~r{^/Users/[^/]+/\.codex/computer-use/Codex Computer Use\.app/Contents/SharedSupport/SkyComputerUseClient\.app/Contents/MacOS/SkyComputerUseClient computer-history mcp$}
  @node_repl ~r{^/Applications/(?:ChatGPT|Codex)\.app/Contents/Resources/cua_node/bin/node_repl$}
  @computer_use_launcher ~r{^/Applications/(?:ChatGPT|Codex)\.app/Contents/Resources/cua_node/bin/node .*/unified-computer-use/[^/]+/scripts/launch\.mjs$}
  @cua_driver_mcp ~r{^(?:/Users/[^/]+/\.local/bin|/Applications/CuaDriver\.app/Contents/MacOS)/cua-driver mcp$}
  @maximum_candidates 250
  @termination_attempts 10
  @termination_poll Duration.milliseconds(100)

  @doc "Returns supported screen-control helpers owned by the current user."
  def scan do
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

  @doc false
  def parse_processes(output, current_uid) do
    output
    |> String.split("\n", trim: true)
    |> Enum.flat_map(&parse_process_row(&1, current_uid))
  end

  @doc "Revalidates a process identity and requests graceful termination."
  def terminate(process), do: terminate(process, &scan/0, &cmd/2, &Process.sleep/1)

  @doc false
  def terminate(
        %{id: id, pid: pid},
        scanner,
        runner,
        sleeper
      )
      when is_tuple(id) and is_integer(pid) and pid > 0 and is_function(scanner, 0) and
             is_function(runner, 2) and is_function(sleeper, 1) do
    with {:ok, processes} <- scanner.() do
      case Enum.find(processes, &(&1.pid == pid)) do
        nil ->
          :already_stopped

        %{id: ^id} ->
          request_termination(pid, runner, sleeper)

        _replacement ->
          {:error, :process_identity_changed}
      end
    end
  end

  def terminate(_process, _scanner, _runner, _sleeper), do: {:error, :invalid_process}

  defp parse_process_row(row, current_uid) do
    case String.split(String.trim(row), ~r/\s+/, parts: 9) do
      [pid_text, ppid_text, uid_text, weekday, month, day, time, year, command] ->
        with {pid, ""} when pid > 0 <- Integer.parse(pid_text),
             {ppid, ""} when ppid >= 0 <- Integer.parse(ppid_text),
             {uid, ""} <- Integer.parse(uid_text),
             true <- uid == current_uid,
             {kind, name} <- classify(command) do
          started_at = Enum.join([weekday, month, day, time, year], " ")

          [
            %{
              id: {kind, pid, started_at},
              kind: kind,
              pid: pid,
              ppid: ppid,
              started_at: started_at,
              name: name
            }
          ]
        else
          _ -> []
        end

      _ ->
        []
    end
  end

  defp classify(command) do
    cond do
      Regex.match?(@computer_use_service, command) ->
        {:computer_use_service, "Codex Computer Use"}

      Regex.match?(@computer_history_mcp, command) ->
        {:computer_history_mcp, "Codex Computer History MCP"}

      Regex.match?(@node_repl, command) ->
        {:node_repl, "node_repl"}

      Regex.match?(@computer_use_launcher, command) ->
        {:computer_use_launcher, "Unified Computer Use"}

      Regex.match?(@cua_driver_mcp, command) ->
        {:cua_driver_mcp, "CUA Driver MCP"}

      true ->
        nil
    end
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
