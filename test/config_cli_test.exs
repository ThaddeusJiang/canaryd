defmodule Canaryd.ConfigCLITest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureIO
  alias Canaryd.{CLI, Config, Setup}

  test "config shows flag and environment values without installing anything" do
    output =
      capture_io(fn ->
        CLI.main(["config", "--check-interval", "2m", "--cleanup-at", "22:30"],
          env: %{"CANARYD_BUILD_RETENTION" => "48h"},
          start: fn -> flunk("read-only command") end
        )
      end)

    assert output =~ "check-interval: 120s"
    assert output =~ "cleanup-at: 22:30"
    assert output =~ "build-retention: 48h"
  end

  test "invalid options exit before helpers or cleanup" do
    for argv <- [
          ["clean", "--build-retention", "0h"],
          ["start", "--cleanup-at", "25:00"],
          ["clean", "--check-interval", "2m"],
          ["start", "--unknown"],
          ["start", "--cleanup-at"]
        ] do
      output =
        capture_io(:stderr, fn ->
          CLI.main(argv,
            env: %{},
            halt: fn 2 -> send(self(), :invalid) end,
            start: fn -> flunk("must not install") end,
            ensure_notification_helper: fn -> flunk("must not install helper") end,
            build_cleanup: fn -> flunk("must not delete") end
          )
        end)

      assert output =~ "configuration error"
      assert_received :invalid
    end
  end

  test "command help is available even with invalid environment" do
    assert capture_io(fn ->
             CLI.main(["start", "--help"], env: %{"CANARYD_CLEANUP_AT" => "bad"})
           end) =~ "CANARYD_CHECK_INTERVAL"
  end

  test "launchd schedule and clean arguments preserve explicit settings" do
    assert {:ok, config} =
             Config.resolve([check_interval: "2m", cleanup_at: "06:35", build_retention: "48h"],
               env: %{}
             )

    [check, clean] = Setup.agent_specs("/tmp/canaryd", config)
    assert check.calendar == Enum.map(0..29, &%{minute: &1 * 2})
    assert clean.calendar == %{hour: 6, minute: 35}
    assert clean.arguments == ["--build-retention", "48h"]
    assert Setup.agent_plist(check) =~ "<key>StartCalendarInterval</key>"
    refute Setup.agent_plist(check) =~ "<key>StartInterval</key>"
    assert Setup.agent_plist(clean) =~ "<string>--build-retention</string>"
    assert Setup.agent_plist(clean) =~ "<string>48h</string>"
    [_, default_clean] = Setup.agent_specs("/tmp/canaryd")
    assert default_clean.arguments == []
  end

  test "custom calendar preserves uniform spacing across midnight" do
    for {raw, count, first, last} <- [
          {"90m", 16, %{hour: 0, minute: 0}, %{hour: 22, minute: 30}},
          {"2h", 12, %{hour: 0, minute: 0}, %{hour: 22, minute: 0}},
          {"24h", 1, %{hour: 0, minute: 0}, %{hour: 0, minute: 0}}
        ] do
      assert {:ok, config} =
               Config.resolve([check_interval: raw, build_retention: "24h"], env: %{})

      [check, _] = Setup.agent_specs("/tmp/canaryd", config)
      assert length(check.calendar) == count
      assert hd(check.calendar) == first
      assert List.last(check.calendar) == last
      assert Setup.agent_plist(check) =~ "<key>Hour</key>"
      refute Setup.agent_plist(check) =~ "<key>StartInterval</key>"
    end
  end

  test "unsupported calendar intervals fail before installation" do
    for raw <- ["1s", "90s", "7m", "25h"] do
      assert {:error, _} = Config.resolve([check_interval: raw], env: %{})
    end

    assert {:ok, _} = Config.resolve([check_interval: "60s", build_retention: "24h"], env: %{})
  end

  test "manual cleanup ignores unrelated schedule environment settings" do
    output =
      capture_io(fn ->
        CLI.main(["clean", "--build-retention", "48h"],
          env: %{"CANARYD_CHECK_INTERVAL" => "invalid", "CANARYD_CLEANUP_AT" => "invalid"},
          ensure_notification_helper: fn -> :ok end,
          build_cleanup: fn -> {:error, :locked} end,
          halt: fn _ -> flunk("unrelated settings must not block cleanup") end
        )
      end)

    assert output =~ "another build cleanup is running"
  end

  test "invalid install settings leave launchd and helper untouched" do
    assert {:error, _} =
             Setup.install(
               check_interval: "bad",
               runner: fn _, _, _ -> flunk("must not touch launchd") end,
               ensure_notification_helper: fn -> flunk("must not install helper") end
             )
  end
end
