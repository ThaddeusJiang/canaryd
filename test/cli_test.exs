defmodule Canaryd.CLITest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Canaryd.CLI

  test "prints the version without installing launchd agents" do
    ensure_installed = fn -> flunk("version must not install launchd agents") end

    assert capture_io(fn -> CLI.main(["--version"], ensure_installed: ensure_installed) end) ==
             "canaryd 0.2.0\n"
  end
end
