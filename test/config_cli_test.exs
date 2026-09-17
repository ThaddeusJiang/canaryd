defmodule Canaryd.ConfigCLITest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureIO
  alias Canaryd.{CLI, Config, Setup, Duration}

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
    assert check.interval == Duration.minutes(2)
    assert clean.calendar == %{hour: 6, minute: 35}
    assert clean.arguments == ["--build-retention", "48h"]
    assert Setup.agent_plist(check) =~ "<integer>120</integer>"
    assert Setup.agent_plist(clean) =~ "<string>--build-retention</string>"
    assert Setup.agent_plist(clean) =~ "<string>48h</string>"
    [_, default_clean] = Setup.agent_specs("/tmp/canaryd")
    assert default_clean.arguments == []
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
