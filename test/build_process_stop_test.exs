defmodule Canaryd.BuildProcessStopTest do
  use ExUnit.Case, async: true

  alias Canaryd.BuildProcessStop

  test "stops only selected build processes and checks they exited" do
    scan_count = start_supervised!({Agent, fn -> 0 end})

    scanner = fn ->
      Agent.get_and_update(scan_count, fn count ->
        processes =
          if count == 0,
            do: [%{pid: 111, ppid: 1, name: "cargo"}, %{pid: 222, ppid: 1, name: "Finder"}],
            else: [%{pid: 222, ppid: 1, name: "Finder"}]

        {{:ok, processes}, count + 1}
      end)
    end

    assert {:ok, 1} =
             BuildProcessStop.run(
               scanner: scanner,
               signaler: fn pid, signal ->
                 send(self(), {pid, signal})
                 :ok
               end,
               sleeper: fn _ -> :ok end
             )

    assert_received {111, :term}
    refute_received {222, _}
    refute_received {111, :kill}
  end

  test "kills a build that did not exit after TERM and fails if it remains" do
    scanner = fn -> {:ok, [%{pid: 111, ppid: 1, name: "rustc"}]} end

    assert {:error, :build_process_active} =
             BuildProcessStop.run(
               scanner: scanner,
               signaler: fn pid, signal ->
                 send(self(), {pid, signal})
                 :ok
               end,
               sleeper: fn _ -> :ok end
             )

    assert_received {111, :term}
    assert_received {111, :kill}
  end

  test "selects compiler descendants but leaves unrelated processes alone" do
    output = """
      111 1 S /Users/test/.cargo/bin/cargo
      112 111 S /bin/sh
      113 112 S /Users/test/tool with spaces
      222 1 S /Applications/Finder.app/Contents/MacOS/Finder
    """

    assert {:ok, processes} = BuildProcessStop.parse(output)
    assert Enum.map(BuildProcessStop.candidates(processes), & &1.pid) == [111, 112, 113]
  end

  test "real TERM signal stops a selected child process" do
    port = Port.open({:spawn_executable, "/bin/sleep"}, [:binary, :exit_status, args: ["30"]])
    {:os_pid, pid} = Port.info(port, :os_pid)

    on_exit(fn ->
      if Port.info(port) do
        System.cmd("/bin/kill", ["-KILL", to_string(pid)], stderr_to_stdout: true)
        Port.close(port)
      end
    end)

    scanner = fn ->
      case System.cmd("/bin/ps", ["-p", to_string(pid), "-o", "stat="], stderr_to_stdout: true) do
        {status, 0} when is_binary(status) ->
          if String.starts_with?(String.trim(status), "Z"),
            do: {:ok, []},
            else: {:ok, [%{pid: pid, ppid: 1, name: "cargo"}]}

        _ ->
          {:ok, []}
      end
    end

    assert {:ok, 1} = BuildProcessStop.run(scanner: scanner)
  end
end
