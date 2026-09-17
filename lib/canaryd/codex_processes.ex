defmodule Canaryd.CodexProcesses do
  @moduledoc """
  Finds Codex screen-control helpers without changing their lifecycle.

  Classification uses fixed command signatures, but command-line arguments are
  discarded before a process leaves the scanner. The long-lived CUA Driver
  service and unrelated Node processes are never actionable. Cumulative CPU time
  is converted from ps hundredths of a second to internal milliseconds.
  """

  alias Canaryd.Duration

  @computer_use_service ~r{^/Users/[^/]+/\.codex/computer-use/Codex Computer Use\.app/Contents/MacOS/SkyComputerUseService$}
  @computer_history_mcp ~r{^/Users/[^/]+/\.codex/computer-use/Codex Computer Use\.app/Contents/SharedSupport/SkyComputerUseClient\.app/Contents/MacOS/SkyComputerUseClient computer-history mcp$}
  @node_repl ~r{^/Applications/(?:ChatGPT|Codex)\.app/Contents/Resources/cua_node/bin/node_repl$}
  @computer_use_launcher ~r{^/Applications/(?:ChatGPT|Codex)\.app/Contents/Resources/cua_node/bin/node .*/unified-computer-use/[^/]+/scripts/launch\.mjs$}
  @bundled_cua_launcher ~r{^/Applications/(ChatGPT|Codex)\.app/Contents/Resources/cua_node/bin/node /Applications/\1\.app/Contents/Resources/cua_node/lib/node_modules/@oai/cua-repl/bin/cua-repl\.mjs$}
  @cua_driver_mcp ~r{^(?:/Users/[^/]+/\.local/bin|/Applications/CuaDriver\.app/Contents/MacOS)/cua-driver mcp$}
  @maximum_candidates 250
  @maximum_rows 16_384
  @maximum_output_bytes 4 * 1024 * 1024
  @command_timeout Duration.seconds(5)

  @doc "Returns supported screen-control helpers owned by the current user."
  def scan do
    with {:ok, uid} <- current_uid(),
         {:ok, output} <- cmd("ps", ["-ww", "-Ao", "pid=,ppid=,uid=,lstart=,time=,command="]) do
      parse_snapshot(output, uid)
    end
  end

  @doc false
  def parse_processes(output, current_uid) do
    case parse_snapshot(output, current_uid) do
      {:ok, processes} -> processes
      {:error, _} -> []
    end
  end

  @doc false
  def parse_snapshot(output, current_uid) do
    rows = String.split(output, "\n", trim: true)

    if length(rows) > @maximum_rows do
      {:error, :too_many_processes}
    else
      parsed = Enum.map(rows, &parse_process_row/1)

      if :error in parsed or length(Enum.uniq_by(parsed, & &1.pid)) != length(parsed) do
        {:error, :invalid_process_snapshot}
      else
        parents = MapSet.new(parsed, & &1.ppid)

        processes =
          for row <- parsed, row.uid == current_uid, row.pid > 0, row.kind != nil do
            row
            |> Map.delete(:uid)
            |> Map.put(:protection, if(MapSet.member?(parents, row.pid), do: :working_children))
          end

        if length(processes) <= @maximum_candidates,
          do: {:ok, processes},
          else: {:error, :too_many_candidates}
      end
    end
  end

  defp parse_process_row(row) do
    case String.split(String.trim(row), ~r/\s+/, parts: 10) do
      [pid_text, ppid_text, uid_text, weekday, month, day, time, year, cpu, command] ->
        with {pid, ""} when pid >= 0 <- Integer.parse(pid_text),
             {ppid, ""} when ppid >= 0 <- Integer.parse(ppid_text),
             {uid, ""} <- Integer.parse(uid_text),
             {:ok, cpu_time} <- parse_cpu_time(cpu) do
          started_at = Enum.join([weekday, month, day, time, year], " ")
          {kind, name} = classify(command) || {nil, nil}

          %{
            id: {kind, pid, started_at},
            kind: kind,
            pid: pid,
            ppid: ppid,
            uid: uid,
            started_at: started_at,
            name: name,
            cpu_time: cpu_time
          }
        else
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp parse_cpu_time(value) do
    case Regex.run(~r/^(?:(\d+):)?(\d+):(\d{2})\.(\d{2})$/, value) do
      [_, hours, minutes, seconds, hundredths] ->
        hours = if hours == "", do: 0, else: String.to_integer(hours)

        {:ok,
         Duration.hours(hours) + Duration.minutes(String.to_integer(minutes)) +
           Duration.seconds(String.to_integer(seconds)) + String.to_integer(hundredths) * 10}

      _ ->
        :error
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

      Regex.match?(@computer_use_launcher, command) or
          Regex.match?(@bundled_cua_launcher, command) ->
        {:computer_use_launcher, "Unified Computer Use"}

      Regex.match?(@cua_driver_mcp, command) ->
        {:cua_driver_mcp, "CUA Driver MCP"}

      true ->
        nil
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

  # Bound both collection time and memory, including unexpectedly large command lines.
  defp cmd(bin, args) do
    case System.find_executable(bin) do
      nil ->
        {:error, :unavailable}

      executable ->
        port =
          Port.open({:spawn_executable, executable}, [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            args: args,
            env: [{~c"LC_ALL", ~c"C"}]
          ])

        try do
          collect(port, [], 0, System.monotonic_time(:millisecond) + @command_timeout)
        after
          if Port.info(port), do: Port.close(port)
        end
    end
  rescue
    _ -> {:error, :unavailable}
  end

  defp collect(port, chunks, size, deadline) do
    remaining = max(0, deadline - System.monotonic_time(:millisecond))

    receive do
      {^port, {:data, data}} when size + byte_size(data) <= @maximum_output_bytes ->
        collect(port, [data | chunks], size + byte_size(data), deadline)

      {^port, {:data, _}} ->
        {:error, :process_output_too_large}

      {^port, {:exit_status, 0}} ->
        {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}

      {^port, {:exit_status, _}} ->
        {:error, :command_failed}
    after
      remaining -> {:error, :command_timeout}
    end
  end
end
