defmodule Canaryd.DiskPressureConfigTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Canaryd.{CLI, DiskPressureConfig}

  @gib 1_024 * 1_024 * 1_024

  setup do
    home =
      Path.join("/private/tmp", "canaryd-storage-config-#{System.unique_integer([:positive])}")

    path = Path.join([home, "Library", "Application Support", "canaryd", "config.conf"])
    on_exit(fn -> File.rm_rf!(home) end)
    %{home: home, path: path}
  end

  test "defaults to 20 GiB and persists a changed threshold", %{home: home, path: path} do
    assert DiskPressureConfig.read(home) == {:ok, 20 * @gib}
    refute File.exists?(path)

    assert DiskPressureConfig.set("30G", home) == {:ok, 30 * @gib}
    assert DiskPressureConfig.read(home) == {:ok, 30 * @gib}
    assert File.read!(path) == "storage-threshold=30G\n"
  end

  test "rejects invalid input without changing the saved threshold", %{home: home, path: path} do
    assert DiskPressureConfig.set("30G", home) == {:ok, 30 * @gib}

    for value <- ["0G", "-1G", "1.5G", "1025G", "30%", "", "20G\n10G", nil] do
      assert {:error, :invalid_threshold} = DiskPressureConfig.set(value, home)
      assert File.read!(path) == "storage-threshold=30G\n"
    end
  end

  test "corrupt configuration prevents use of the default", %{home: home, path: path} do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "storage-threshold=invalid\n")
    assert DiskPressureConfig.read(home) == {:error, :invalid_threshold}
  end

  test "reads legacy setting until overridden in the shared file", %{home: home} do
    legacy = Path.join([home, "Library", "Application Support", "canaryd", "storage-threshold"])
    File.mkdir_p!(Path.dirname(legacy))
    File.write!(legacy, "25G\n")
    assert DiskPressureConfig.read(home) == {:ok, 25 * @gib}
    assert DiskPressureConfig.set("30G", home) == {:ok, 30 * @gib}
    assert DiskPressureConfig.read(home) == {:ok, 30 * @gib}
    assert File.read!(legacy) == "25G\n"
  end

  test "CLI shows and changes the threshold without starting monitoring", %{home: home} do
    options = [
      home: home,
      start: fn -> flunk("config must not start monitoring") end,
      build_cleanup: fn -> flunk("config must not run cleanup") end
    ]

    assert capture_io(fn -> CLI.main(["config", "storage-threshold"], options) end) ==
             "storage threshold: 20G\n"

    assert capture_io(fn -> CLI.main(["config", "storage-threshold", "30G"], options) end) ==
             "storage threshold: 30G\n"

    assert capture_io(fn -> CLI.main(["config", "storage-threshold"], options) end) ==
             "storage threshold: 30G\n"

    assert capture_io(fn -> CLI.main(["config", "storage-threshold", "0G"], options) end) =~
             "storage threshold failed:"
  end
end
