defmodule Canaryd.BuildCleanupConfigTest do
  use ExUnit.Case, async: true

  alias Canaryd.{BuildCleanupConfig, Duration}

  setup do
    home = Path.join("/private/tmp", "canaryd-config-#{System.unique_integer([:positive])}")

    path =
      Path.join([home, "Library", "Application Support", "canaryd", "build-cleanup-retention"])

    on_exit(fn -> File.rm_rf!(home) end)
    %{home: home, path: path}
  end

  test "a missing setting uses 24 hours without writing a file", context do
    assert BuildCleanupConfig.default_retention() == Duration.hours(24)
    assert BuildCleanupConfig.read(context.home) == {:ok, Duration.hours(24)}
    refute File.exists?(context.path)
  end

  test "persists normalized whole hours including both supported limits", context do
    for {input, expected} <- [{"1h", 1}, {"48", 48}, {"87600h", 87_600}] do
      assert BuildCleanupConfig.set(input, context.home) == {:ok, Duration.hours(expected)}
      assert BuildCleanupConfig.read(context.home) == {:ok, Duration.hours(expected)}
      assert File.read!(context.path) == "#{expected}h\n"
      assert BuildCleanupConfig.format(Duration.hours(expected)) == "#{expected}h"
    end

    assert File.ls!(Path.dirname(context.path)) == ["build-cleanup-retention"]
  end

  test "invalid input leaves the prior value untouched", context do
    assert {:ok, _retention} = BuildCleanupConfig.set("48h", context.home)

    for input <- [
          "0h",
          "-1h",
          "87601h",
          "1.5h",
          "2d",
          "1h2h",
          "",
          "1\n2h",
          String.duplicate("1", 65),
          <<255>>,
          nil
        ] do
      assert BuildCleanupConfig.set(input, context.home) == {:error, :invalid_retention}
      assert File.read!(context.path) == "48h\n"
    end
  end

  test "corrupt, empty, and oversized files fail closed", context do
    File.mkdir_p!(Path.dirname(context.path))

    for contents <- ["", "invalid", "0h", "87601h", <<255>>] do
      File.write!(context.path, contents)
      assert BuildCleanupConfig.read(context.home) == {:error, :invalid_retention}
    end

    File.write!(context.path, "24h" <> String.duplicate(" ", 62))
    assert BuildCleanupConfig.read(context.home) == {:error, :config_too_large}
  end

  test "rejects non-regular configuration files and preserves them on write failure", context do
    File.mkdir_p!(context.path)
    marker = Path.join(context.path, "keep")
    File.write!(marker, "original")

    assert BuildCleanupConfig.read(context.home) == {:error, :invalid_config_file}
    assert {:error, _reason} = BuildCleanupConfig.set("48h", context.home)
    assert File.read!(marker) == "original"
    assert File.ls!(Path.dirname(context.path)) == ["build-cleanup-retention"]
  end

  test "unreadable configuration returns an error without falling back", context do
    assert {:ok, _retention} = BuildCleanupConfig.set("48h", context.home)
    File.chmod!(context.path, 0)
    on_exit(fn -> File.chmod(context.path, 0o600) end)

    assert BuildCleanupConfig.read(context.home) == {:error, :eacces}
  end

  test "a blocked parent returns an error without modifying the blocking file", context do
    File.mkdir_p!(context.home)
    blocker = Path.join(context.home, "Library")
    File.write!(blocker, "keep")

    assert {:error, _reason} = BuildCleanupConfig.read(context.home)
    assert {:error, _reason} = BuildCleanupConfig.set("48h", context.home)
    assert File.read!(blocker) == "keep"
  end
end
