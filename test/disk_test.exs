defmodule Canaryd.DiskTest do
  use ExUnit.Case, async: true

  alias Canaryd.Disk

  test "parses Data volume usage" do
    output =
      "Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/disk3s5 100000 95000 5000 95% /System/Volumes/Data\n"

    assert {:ok, usage} = Disk.parse_df(output)
    assert usage.used_percent == 95
    assert usage.available_bytes == 5_120_000
    assert Disk.pressure?(usage)
  end

  test "requires valid df output" do
    assert Disk.parse_df("invalid") == {:error, :invalid_output}
  end

  test "recognizes the absolute free-space guard" do
    refute Disk.pressure?(%{used_percent: 80, available_bytes: 10 * 1_024 * 1_024 * 1_024})
    assert Disk.pressure?(%{used_percent: 80, available_bytes: 9 * 1_024 * 1_024 * 1_024})
  end

  test "ignores used percentage when enough space is available" do
    refute Disk.pressure?(%{used_percent: 99, available_bytes: 25 * 1_024 * 1_024 * 1_024})
  end
end
