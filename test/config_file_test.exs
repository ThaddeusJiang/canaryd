defmodule Canaryd.ConfigFileTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Canaryd.{BuildCleanupConfig, CLI, ConfigFile, DiskPressureConfig, PolicyConfig}

  setup do
    home =
      Path.join(System.tmp_dir!(), "canaryd-config-file-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(home) end)
    %{home: home, path: ConfigFile.path(home)}
  end

  test "commands and manual edits share one file while preserving comments", %{
    home: home,
    path: path
  } do
    assert capture_io(fn -> CLI.main(["config", "--path"], home: home) end) == path <> "\n"

    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "# My settings\nstorage-threshold = 25G\nswap-min-growth=768M\n")

    assert DiskPressureConfig.read(home) == {:ok, 25 * 1_024 * 1_024 * 1_024}
    assert PolicyConfig.read(:swap_min_growth, home) == {:ok, 768}

    assert capture_io(fn -> CLI.main(["config", "storage-threshold", "30G"], home: home) end) ==
             "storage threshold: 30G\n"

    assert File.read!(path) ==
             "# My settings\nstorage-threshold=30G\nswap-min-growth=768M\n"

    assert capture_io(fn -> CLI.main(["config", "build-retention", "48h"], home: home) end) ==
             "build retention: 48h\n"

    assert BuildCleanupConfig.read(home) == {:ok, Canaryd.Duration.hours(48)}
    assert File.read!(path) =~ "build-retention=48h\n"
  end

  test "a central key overrides its legacy file and other legacy keys remain active", %{
    home: home,
    path: path
  } do
    old = Path.join(Path.dirname(path), "thresholds")
    File.mkdir_p!(old)
    File.write!(Path.join(old, "memory-rss"), "2048M\n")
    File.write!(Path.join(old, "swap-min-growth"), "1024M\n")
    File.write!(path, "swap-min-growth=768M\n")

    assert {:ok, policy} = PolicyConfig.read_all(home)
    assert policy.memory_rss == 2048
    assert policy.swap_min_growth == 768
  end

  test "invalid syntax and duplicate keys fail closed without overwriting the file", %{
    home: home,
    path: path
  } do
    File.mkdir_p!(Path.dirname(path))

    for contents <- [
          "unknown=1\n",
          "storage-threshold=20G\nstorage-threshold=25G\n",
          "not-an-assignment\n",
          <<255>>
        ] do
      File.write!(path, contents)
      assert {:error, {_, :invalid_config_file}} = PolicyConfig.read_all(home)
      assert DiskPressureConfig.read(home) == {:error, :invalid_config_file}
      assert ConfigFile.put("storage-threshold", "30G", home) == {:error, :invalid_config_file}
      assert File.read!(path) == contents
    end
  end

  test "manual policy values retain relationship validation", %{home: home, path: path} do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "memory-min-spacing=15m\n")

    assert PolicyConfig.read_all(home) == {:error, :invalid_spacing_range}
    assert PolicyConfig.set("swap-min-growth", "768M", home) == {:error, :invalid_spacing_range}
    assert File.read!(path) == "memory-min-spacing=15m\n"
  end
end
