defmodule Canaryd.PlaywrightBrowsersTest do
  use ExUnit.Case, async: true

  alias Canaryd.PlaywrightBrowsers

  @chrome_arm64 "/Users/amami/Library/Caches/ms-playwright/chromium-1237/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing"
  @chrome_x64 "/Users/amami/Library/Caches/ms-playwright/chromium-1237/chrome-mac-x64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing"

  test "finds only current-user Playwright Chrome for Testing main processes" do
    output = """
      737 1 501 Fri Sep 11 00:00:01 2026 #{@chrome_arm64}
     45547 1 501 Fri Sep 11 01:00:02 2026 #{@chrome_arm64} --user-data-dir=/Users/amami/.playwright/profiles/user-web --remote-debugging-port=9222
     45569 45547 501 Fri Sep 11 01:00:03 2026 /Users/amami/Library/Caches/ms-playwright/chromium-1237/chrome-mac-arm64/Google Chrome for Testing.app/Contents/Frameworks/Google Chrome for Testing Framework.framework/Versions/152.0.7977.8/Helpers/Google Chrome for Testing Helper.app/Contents/MacOS/Google Chrome for Testing Helper --type=gpu-process
       900 1 501 Fri Sep 11 00:00:04 2026 /Users/amami/Library/Caches/ms-playwright/chromium-1237/chrome-mac-arm64/Google Chrome for Testing.app/Contents/Frameworks/Google Chrome for Testing Framework.framework/Versions/152.0.7977.8/Helpers/chrome_crashpad_handler --monitor-self
       721 1 501 Fri Sep 11 00:00:05 2026 /Applications/Google Chrome.app/Contents/MacOS/Google Chrome
      2593 1 501 Fri Sep 11 00:00:06 2026 /Applications/Clicknow.app/Contents/MacOS/Clicknow
       738 1 502 Fri Sep 11 00:00:07 2026 #{@chrome_arm64}
       739 1 501 Fri Sep 11 00:00:08 2026 #{@chrome_x64}
    malformed
    """

    assert PlaywrightBrowsers.parse_processes(output, 501) == [
             browser(737, 1, "Fri Sep 11 00:00:01 2026"),
             browser(45_547, 1, "Fri Sep 11 01:00:02 2026"),
             browser(739, 1, "Fri Sep 11 00:00:08 2026")
           ]
  end

  test "finds current-user Playwright runners without keeping command lines" do
    output = """
        99 501 /Users/amami/.local/bin/playwright-cli attach --cdp=chrome
       100 501 /Users/amami/.local/share/mise/installs/node/24.16.0/bin/node /Users/amami/git/foo/node_modules/playwright/cli.js test
       101 501 /Users/amami/git/foo/node_modules/.bin/playwright test
       102 501 /Users/amami/.local/share/mise/installs/node/24.16.0/bin/node /Users/amami/git/foo/server.js
       103 502 /Users/amami/.local/bin/playwright-cli attach --cdp=chrome
       737 501 #{@chrome_arm64}
    """

    runners = PlaywrightBrowsers.parse_automation_processes(output, 501)

    assert runners == [
             %{pid: 99, name: "playwright"},
             %{pid: 100, name: "playwright"},
             %{pid: 101, name: "playwright"}
           ]

    refute Enum.any?(runners, &Map.has_key?(&1, :command))
  end

  test "terminates only a revalidated exact browser and never sends SIGKILL" do
    target = browser(737, 1, "Fri Sep 11 00:00:01 2026")
    scanner = fn -> {:ok, [target]} end

    runner = fn
      "kill", ["-TERM", "737"] ->
        send(self(), {:command, "kill", ["-TERM", "737"]})
        {:ok, ""}

      "kill", ["-0", "737"] ->
        {:error, "not running"}
    end

    assert :ok =
             PlaywrightBrowsers.terminate(
               target,
               scanner,
               runner,
               fn _duration -> :ok end,
               1
             )

    assert_received {:command, "kill", ["-TERM", "737"]}
    refute_received {:command, "kill", ["-KILL", _pid]}
  end

  test "does not terminate a reused PID, an already stopped browser, or the frontmost browser" do
    target = browser(737, 1, "Fri Sep 11 00:00:01 2026")
    replacement = browser(737, 1, "Fri Sep 11 02:00:01 2026")
    runner = fn _bin, _args -> flunk("termination command must not run") end
    sleeper = fn _duration -> :ok end

    assert {:error, :process_identity_changed} =
             PlaywrightBrowsers.terminate(
               target,
               fn -> {:ok, [replacement]} end,
               runner,
               sleeper,
               1
             )

    assert :already_stopped =
             PlaywrightBrowsers.terminate(target, fn -> {:ok, []} end, runner, sleeper, 1)

    assert {:error, :browser_became_frontmost} =
             PlaywrightBrowsers.terminate(
               target,
               fn -> {:ok, [target]} end,
               runner,
               sleeper,
               737
             )
  end

  test "drops the frontmost Chrome for Testing process from leftover candidates" do
    browsers = [
      browser(737, 1, "Fri Sep 11 00:00:01 2026"),
      browser(739, 1, "Fri Sep 11 00:00:08 2026")
    ]

    assert PlaywrightBrowsers.exclude_frontmost(browsers, 737) == [
             browser(739, 1, "Fri Sep 11 00:00:08 2026")
           ]
  end

  defp browser(pid, ppid, started_at) do
    %{
      id: {:chrome_for_testing, pid, started_at},
      kind: :chrome_for_testing,
      pid: pid,
      ppid: ppid,
      started_at: started_at,
      name: "Chrome for Testing"
    }
  end
end
