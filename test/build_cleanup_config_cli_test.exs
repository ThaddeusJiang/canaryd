defmodule Canaryd.BuildCleanupConfigCLITest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Canaryd.CLI

  setup do
    home = Path.join("/private/tmp", "canaryd-config-cli-#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    on_exit(fn -> File.rm_rf!(home) end)

    options = [
      home: home,
      ensure_notification_helper: fn -> flunk("config must not prepare notifications") end,
      start: fn -> flunk("config must not start background monitoring") end,
      build_cleanup: fn -> flunk("config must not run cleanup") end
    ]

    %{home: home, options: options}
  end

  test "shows the default and persists a user retention for subsequent commands", context do
    assert command([], context.options) == "build retention: 24h\n"
    assert command(["48h"], context.options) == "build retention: 48h\n"
    assert command([], context.options) == "build retention: 48h\n"

    path =
      Path.join([
        context.home,
        "Library",
        "Application Support",
        "canaryd",
        "build-cleanup-retention"
      ])

    assert File.read!(path) == "48h\n"
  end

  test "reports invalid retention without replacing the user's setting", context do
    command(["48h"], context.options)
    output = command(["0h"], context.options)

    assert output =~ "build retention failed:"
    assert output =~ "1h..87600h"
    assert command([], context.options) == "build retention: 48h\n"
  end

  test "reports corrupt settings instead of displaying the default", context do
    command(["48h"], context.options)

    path =
      Path.join([
        context.home,
        "Library",
        "Application Support",
        "canaryd",
        "build-cleanup-retention"
      ])

    File.write!(path, "corrupt")

    output = command([], context.options)
    assert output =~ "build retention failed:"
    assert output =~ "1h..87600h"
    refute output =~ "build retention: 24h"
  end

  test "help documents the default and configuration command", context do
    output = capture_io(fn -> CLI.main(["--help"], context.options) end)
    assert output =~ "canaryd config build-retention [Nh]"
    assert output =~ "default: 24h"
  end

  defp command(arguments, options) do
    capture_io(fn -> CLI.main(["config", "build-retention" | arguments], options) end)
  end
end
