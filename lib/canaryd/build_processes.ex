defmodule Canaryd.BuildProcesses do
  @moduledoc """
  Finds current-user compiler processes that may outlive their launcher.
  """

  @tools ~w(cargo rustc clang clang++ cmake ninja make xcodebuild xctest)

  @doc "Returns current-user build processes without retaining command lines."
  def scan do
    with {:ok, uid} <- current_uid(),
         {:ok, output} <- cmd("ps", ["-Ao", "pid=,ppid=,uid=,pcpu=,rss=,command="]) do
      {:ok, parse(output, uid)}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  def parse(output, current_uid) when is_binary(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.flat_map(&parse_row(&1, current_uid))
  end

  def parse(_output, _current_uid), do: []

  defp parse_row(row, current_uid) do
    case String.split(String.trim(row), ~r/\s+/, parts: 6) do
      [pid_text, ppid_text, uid_text, cpu_text, rss_text, command] ->
        with {pid, ""} when pid > 0 <- Integer.parse(pid_text),
             {ppid, ""} when ppid >= 0 <- Integer.parse(ppid_text),
             {uid, ""} <- Integer.parse(uid_text),
             true <- uid == current_uid,
             {cpu_percent, ""} <- Float.parse(cpu_text),
             {rss_kb, ""} when rss_kb >= 0 <- Integer.parse(rss_text),
             {:ok, name} <- tool_name(command) do
          [
            %{
              id: {name, pid},
              name: name,
              pid: pid,
              ppid: ppid,
              cpu_percent: cpu_percent,
              rss_mb: Float.round(rss_kb / 1_024, 1),
              detached: ppid == 1
            }
          ]
        else
          _ -> []
        end

      _ ->
        []
    end
  end

  defp tool_name(command) do
    case String.split(command, ~r/\s+/, parts: 2) do
      [executable | _] ->
        executable = Path.basename(executable)

        cond do
          executable in @tools -> {:ok, executable}
          String.starts_with?(executable, "clang-") -> {:ok, "clang"}
          true -> :skip
        end

      _ ->
        :skip
    end
  end

  defp current_uid do
    case cmd("id", ["-u"]) do
      {:ok, output} ->
        case Integer.parse(String.trim(output)) do
          {uid, ""} -> {:ok, uid}
          _ -> {:error, :invalid_uid}
        end

      error ->
        error
    end
  end

  defp cmd(bin, args) do
    case System.cmd(bin, args, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {_output, status} -> {:error, {:command_failed, bin, status}}
    end
  rescue
    _ -> {:error, :unavailable}
  end
end
