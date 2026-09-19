defmodule Canaryd.CodexProcessesTest do
  use ExUnit.Case, async: true

  alias Canaryd.CodexProcesses

  @client_path "/Users/amami/.codex/computer-use/Codex Computer Use.app/Contents/SharedSupport/SkyComputerUseClient.app/Contents/MacOS/SkyComputerUseClient"

  test "recognizes current-user Computer History MCP clients without retaining command lines" do
    output = """
      49 2072 501 Mon Sep  7 20:08:09 2026 0:00.13 #{@client_path} computer-history mcp
      50 2072 502 Mon Sep  7 20:09:10 2026 0:00.13 #{@client_path} computer-history mcp
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
      output = "49 2072 501 Mon Sep 7 20:08:09 2026 0:00.13 #{command}"
      assert CodexProcesses.parse_processes(output, 501) == [], command
    end
  end

  test "finds only current-user Codex screen-control helpers" do
    output = """
      42 1228 501 Mon Sep  7 20:01:02 2026 0:00.13 /Users/amami/.codex/computer-use/Codex Computer Use.app/Contents/MacOS/SkyComputerUseService
      43 2072 501 Mon Sep  7 20:02:03 2026 0:00.13 /Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node_repl
      44 2072 501 Mon Sep  7 20:03:04 2026 0:00.13 /Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node /Users/amami/.codex/plugins/cache/openai-bundled/unified-computer-use/26.831.20005/scripts/launch.mjs
      45 2072 501 Mon Sep  7 20:04:05 2026 0:00.13 /Users/amami/.local/bin/cua-driver mcp
      46 1 501 Mon Sep  7 20:05:06 2026 0:00.13 /Applications/CuaDriver.app/Contents/MacOS/cua-driver serve
      47 2072 501 Mon Sep  7 20:06:07 2026 0:00.13 /Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node ./server.mjs
      48 2072 502 Mon Sep  7 20:07:08 2026 0:00.13 /Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node_repl
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

  test "recognizes bundled CUA launchers and protects initialized execution hosts" do
    for app <- ["ChatGPT", "Codex"] do
      root = "/Applications/#{app}.app/Contents/Resources/cua_node"

      output = """
      10 100 501 Mon Sep 7 20:02:03 2026 0:00.04 #{root}/bin/node #{root}/lib/node_modules/@oai/cua-repl/bin/cua-repl.mjs
      11 10 501 Mon Sep 7 20:02:03 2026 0:00.14 #{root}/bin/node_repl
      12 100 501 Mon Sep 7 20:02:03 2026 0:00.13 #{root}/bin/node_repl
      13 12 502 Mon Sep 7 20:02:03 2026 1:12.34 /bin/sleep 100
      """

      assert [launcher, empty, initialized] = CodexProcesses.parse_processes(output, 501)
      assert launcher.kind == :computer_use_launcher
      assert launcher.protection == :working_children
      assert empty.protection == nil
      assert initialized.protection == :working_children
      refute Map.has_key?(empty, :command)
      assert empty.cpu_time == 140
    end
  end

  test "rejects spoofed bundled launcher paths and unexpected arguments" do
    root = "/Applications/ChatGPT.app/Contents/Resources/cua_node"
    command = "#{root}/bin/node #{root}/lib/node_modules/@oai/cua-repl/bin/cua-repl.mjs"

    for changed <- [
          command <> " --extra",
          String.replace(command, "lib/node_modules", "tmp"),
          String.replace(
            command,
            "ChatGPT.app/Contents/Resources/cua_node/lib",
            "Codex.app/Contents/Resources/cua_node/lib"
          )
        ] do
      assert [] ==
               CodexProcesses.parse_processes(
                 "10 100 501 Mon Sep 7 20:02:03 2026 0:00.04 #{changed}",
                 501
               )
    end
  end

  test "malformed snapshots and candidate overflow fail closed" do
    assert {:error, :invalid_process_snapshot} = CodexProcesses.parse_snapshot("malformed", 501)

    row =
      "10 100 501 Mon Sep 7 20:02:03 2026 0:00.13 /Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node_repl"

    assert {:error, :invalid_process_snapshot} =
             CodexProcesses.parse_snapshot(row <> "\nmalformed", 501)

    rows = Enum.map_join(1..251, "\n", &String.replace_prefix(row, "10 ", "#{&1} "))
    assert {:error, :too_many_candidates} = CodexProcesses.parse_snapshot(rows, 501)
  end

  test "parses long cumulative CPU times and rejects duplicate rows" do
    row =
      "43 100 501 Mon Sep 7 20:02:03 2026 125:01.23 /Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node_repl"

    assert [target] = CodexProcesses.parse_processes(row, 501)
    assert target.cpu_time == 7_501_230

    assert {:error, :invalid_process_snapshot} =
             CodexProcesses.parse_snapshot(row <> "\n" <> row, 501)

    assert {:error, :invalid_process_snapshot} =
             CodexProcesses.parse_snapshot(String.replace(row, "125:01.23", "unknown"), 501)
  end

  defp process(kind, pid, ppid, started_at, name) do
    %{
      id: {kind, pid, started_at},
      kind: kind,
      pid: pid,
      ppid: ppid,
      started_at: started_at,
      name: name,
      cpu_time: 130,
      protection: nil
    }
  end
end
