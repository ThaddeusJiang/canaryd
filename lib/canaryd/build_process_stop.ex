defmodule Canaryd.BuildProcessStop do
  @moduledoc false

  alias Canaryd.BazelCache

  @build_tools MapSet.new(
                 ~w(cargo rustc clang clang++ cmake ninja make xcodebuild bazel bazelisk gcc g++ cc1 swiftc ld)
               )

  @doc "Stop current-user build processes before emergency artifact removal."
  def run(options \\ []) do
    scanner = Keyword.get(options, :scanner, &scan/0)
    signaler = Keyword.get(options, :signaler, &signal/2)
    sleeper = Keyword.get(options, :sleeper, &Process.sleep/1)

    with {:ok, processes} <- scanner.(),
         targets = candidates(processes),
         :ok <- signal_all(targets, :term, signaler, scanner),
         :ok <- wait_for_exit(targets, scanner, signaler, sleeper) do
      {:ok, length(targets)}
    end
  end

  @doc false
  def candidates(processes) do
    roots =
      processes
      |> Enum.filter(&MapSet.member?(@build_tools, &1.name))
      |> MapSet.new(& &1.pid)

    pids = descendants(processes, roots)
    Enum.filter(processes, &MapSet.member?(pids, &1.pid))
  end

  defp descendants(processes, pids) do
    next =
      Enum.reduce(processes, pids, fn process, acc ->
        if MapSet.member?(acc, process.ppid), do: MapSet.put(acc, process.pid), else: acc
      end)

    if MapSet.equal?(next, pids), do: pids, else: descendants(processes, next)
  end

  defp scan do
    with {:ok, uid} <- BazelCache.command("/usr/bin/id", ["-u"]),
         {owner, ""} when owner >= 0 <- Integer.parse(String.trim(uid)),
         {:ok, output} <-
           BazelCache.command("/bin/ps", [
             "-ww",
             "-U",
             to_string(owner),
             "-o",
             "pid=,ppid=,stat=,comm="
           ]) do
      parse(output)
    else
      _ -> {:error, :process_scan_unavailable}
    end
  end

  @doc false
  def parse(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.reduce_while({:ok, []}, fn line, {:ok, acc} ->
      case String.split(String.trim(line), ~r/\s+/, parts: 4) do
        [pid_text, ppid_text, status, command] ->
          with {pid, ""} when pid > 1 <- Integer.parse(pid_text),
               {ppid, ""} when ppid >= 0 <- Integer.parse(ppid_text),
               true <- command != "" do
            if String.starts_with?(status, "Z") do
              {:cont, {:ok, acc}}
            else
              {:cont, {:ok, [%{pid: pid, ppid: ppid, name: Path.basename(command)} | acc]}}
            end
          else
            _ -> {:halt, {:error, :process_scan_unavailable}}
          end

        _ ->
          {:halt, {:error, :process_scan_unavailable}}
      end
    end)
    |> case do
      {:ok, []} -> {:error, :process_scan_unavailable}
      {:ok, processes} -> {:ok, Enum.reverse(processes)}
      error -> error
    end
  end

  defp wait_for_exit([], _scanner, _signaler, _sleeper), do: :ok

  defp wait_for_exit(targets, scanner, signaler, sleeper) do
    sleeper.(500)

    with {:ok, processes} <- scanner.(),
         remaining = matching(targets, processes),
         :ok <- signal_all(remaining, :kill, signaler, scanner) do
      sleeper.(100)

      case scanner.() do
        {:ok, processes} ->
          if matching(targets, processes) == [], do: :ok, else: {:error, :build_process_active}

        error ->
          error
      end
    end
  end

  defp matching(targets, processes) do
    identities = MapSet.new(targets, &{&1.pid, &1.name})
    Enum.filter(processes, &MapSet.member?(identities, {&1.pid, &1.name}))
  end

  defp signal_all(processes, signal, signaler, scanner) do
    Enum.reduce_while(processes, :ok, fn process, :ok ->
      case signaler.(process.pid, signal) do
        :ok ->
          {:cont, :ok}

        error ->
          case scanner.() do
            {:ok, current} ->
              if matching([process], current) == [],
                do: {:cont, :ok},
                else: {:halt, error}

            scan_error ->
              {:halt, scan_error}
          end
      end
    end)
  end

  defp signal(pid, signal) when is_integer(pid) and pid > 1 and signal in [:term, :kill] do
    flag = if signal == :term, do: "-TERM", else: "-KILL"

    case System.cmd("/bin/kill", [flag, to_string(pid)], stderr_to_stdout: true) do
      {_, 0} -> :ok
      {_, _} -> {:error, :signal_failed}
    end
  rescue
    _ -> {:error, :signal_failed}
  end
end
