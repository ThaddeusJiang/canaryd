defmodule Canaryd.CodexProcessesTest do
  use ExUnit.Case, async: true

  alias Canaryd.{CodexProcessMonitor, CodexProcesses, Duration}

  @client_path "/Users/amami/.codex/computer-use/Codex Computer Use.app/Contents/SharedSupport/SkyComputerUseClient.app/Contents/MacOS/SkyComputerUseClient"

  test "recognizes current-user Computer History MCP clients without retaining command lines" do
    output = """
      49 2072 501 Mon Sep  7 20:08:09 2026 #{@client_path} computer-history mcp
      50 2072 502 Mon Sep  7 20:09:10 2026 #{@client_path} computer-history mcp
    """

    assert CodexProcesses.parse_processes(output, 501) == [
             process(
               :computer_history_mcp,
               49,
               2072,
               "Mon Sep 7 20:08:09 2026",
               "Codex Computer History MCP"
             )
           ]
  end

  test "protects continuous Computer History capture and unrecognized client commands" do
    for command <- [
          "#{@client_path} computer-history event-stream",
          "#{@client_path} event-stream",
          "#{@client_path} computer-history",
          @client_path,
          "#{@client_path} computer-history mcp --unknown-mode",
          "#{@client_path} computer-history mcp-server",
          "/tmp/SkyComputerUseClient computer-history mcp",
          "#{@client_path}.backup computer-history mcp",
          "/bin/echo #{@client_path} computer-history mcp"
        ] do
      output = "49 2072 501 Mon Sep 7 20:08:09 2026 #{command}"
      assert CodexProcesses.parse_processes(output, 501) == [], command
    end
  end

  test "parsed clients require a fresh three-round sequence after user activity" do
    output = "49 2072 501 Mon Sep 7 20:08:09 2026 #{@client_path} computer-history mcp"
    [client] = CodexProcesses.parse_processes(output, 501)
    idle = Duration.minutes(30)

    {state, [{:detected, ^client, 1}]} =
      CodexProcessMonitor.evaluate(CodexProcessMonitor.default_state(), [client], idle)

    {state, []} = CodexProcessMonitor.evaluate(state, [client], Duration.minutes(29))
    {state, [{:detected, ^client, 1}]} = CodexProcessMonitor.evaluate(state, [client], idle)
    {state, [{:detected, ^client, 2}]} = CodexProcessMonitor.evaluate(state, [client], idle)
    {_state, [{:terminate, ^client}]} = CodexProcessMonitor.evaluate(state, [client], idle)

    replaced = String.replace(output, "computer-history mcp", "computer-history event-stream")
    scanner = fn -> {:ok, CodexProcesses.parse_processes(replaced, 501)} end
    runner = fn _bin, _args -> flunk("a client that changed mode must not be terminated") end

    assert :already_stopped =
             CodexProcesses.terminate(client, scanner, runner, fn _duration -> :ok end)
  end

  test "finds only current-user Codex screen-control helpers" do
    output = """
      42 1228 501 Mon Sep  7 20:01:02 2026 /Users/amami/.codex/computer-use/Codex Computer Use.app/Contents/MacOS/SkyComputerUseService
      43 2072 501 Mon Sep  7 20:02:03 2026 /Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node_repl
      44 2072 501 Mon Sep  7 20:03:04 2026 /Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node /Users/amami/.codex/plugins/cache/openai-bundled/unified-computer-use/26.831.20005/scripts/launch.mjs
      45 2072 501 Mon Sep  7 20:04:05 2026 /Users/amami/.local/bin/cua-driver mcp
      46 1 501 Mon Sep  7 20:05:06 2026 /Applications/CuaDriver.app/Contents/MacOS/cua-driver serve
      47 2072 501 Mon Sep  7 20:06:07 2026 /Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node ./server.mjs
      48 2072 502 Mon Sep  7 20:07:08 2026 /Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node_repl
      malformed
    """

    assert CodexProcesses.parse_processes(output, 501) == [
             process(
               :computer_use_service,
               42,
               1228,
               "Mon Sep 7 20:01:02 2026",
               "Codex Computer Use"
             ),
             process(:node_repl, 43, 2072, "Mon Sep 7 20:02:03 2026", "node_repl"),
             process(
               :computer_use_launcher,
               44,
               2072,
               "Mon Sep 7 20:03:04 2026",
               "Unified Computer Use"
             ),
             process(:cua_driver_mcp, 45, 2072, "Mon Sep 7 20:04:05 2026", "CUA Driver MCP")
           ]
  end

  test "terminates only a revalidated exact process and never sends SIGKILL" do
    target = process(:node_repl, 43, 2072, "Mon Sep 7 20:02:03 2026", "node_repl")
    scanner = fn -> {:ok, [target]} end

    runner = fn
      "kill", ["-TERM", "43"] ->
        send(self(), {:command, "kill", ["-TERM", "43"]})
        {:ok, ""}

      "kill", ["-0", "43"] ->
        {:error, "not running"}
    end

    assert :ok = CodexProcesses.terminate(target, scanner, runner, fn _duration -> :ok end)
    assert_received {:command, "kill", ["-TERM", "43"]}
    refute_received {:command, "kill", ["-KILL", _pid]}
  end

  test "does not terminate a reused PID or an already stopped process" do
    target = process(:node_repl, 43, 2072, "Mon Sep 7 20:02:03 2026", "node_repl")

    replacement =
      process(:node_repl, 43, 9999, "Mon Sep 7 21:02:03 2026", "node_repl")

    runner = fn _bin, _args -> flunk("termination command must not run") end
    sleeper = fn _duration -> :ok end

    assert {:error, :process_identity_changed} =
             CodexProcesses.terminate(target, fn -> {:ok, [replacement]} end, runner, sleeper)

    assert :already_stopped =
             CodexProcesses.terminate(target, fn -> {:ok, []} end, runner, sleeper)
  end

  defp process(kind, pid, ppid, started_at, name) do
    %{
      id: {kind, pid, started_at},
      kind: kind,
      pid: pid,
      ppid: ppid,
      started_at: started_at,
      name: name
    }
  end
end
