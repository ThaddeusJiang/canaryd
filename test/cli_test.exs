defmodule Canaryd.CLITest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Canaryd.CLI

  test "prints the version without installing the launchd agent" do
    ensure_installed = fn -> flunk("version must not install the launchd agent") end

    assert capture_io(fn -> CLI.main(["--version"], ensure_installed: ensure_installed) end) ==
             "canaryd 0.4.3\n"
  end
end
