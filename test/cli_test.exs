defmodule Canaryd.CLITest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Canaryd.CLI

  test "formats UTC timestamps in local time with an explicit offset" do
    assert CLI.format_datetime(~U[2026-09-04 10:43:36Z], 9 * 60 * 60) ==
             "2026-09-04 19:43:36 UTC+09:00"

    assert CLI.format_datetime(~U[2026-09-04 10:43:36Z], -(3 * 60 + 30) * 60) ==
             "2026-09-04 07:13:36 UTC-03:30"
  end

  test "prints the version without installing the launchd agent" do
    ensure_installed = fn -> flunk("version must not install the launchd agent") end

    assert capture_io(fn -> CLI.main(["--version"], ensure_installed: ensure_installed) end) ==
             "canaryd 0.4.4\n"
  end

  test "runs the build cleanup command through the CLI" do
    build_cleanup = fn ->
      send(self(), :build_cleanup_called)
      {:error, :locked}
    end

    assert capture_io(fn ->
             CLI.main(["clean"],
               ensure_installed: fn -> :ok end,
               build_cleanup: build_cleanup
             )
           end) == "another build cleanup is running, skipping\n"

    assert_received :build_cleanup_called
  end
end
