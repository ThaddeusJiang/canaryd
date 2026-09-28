defmodule Canaryd.SwapTest do
  use ExUnit.Case, async: true

  alias Canaryd.Swap

  test "parses macOS swapusage units" do
    assert {:ok, usage} = Swap.parse("total = 10.24G used = 6.45G free = 3.79G (encrypted)\n")
    assert usage.total_bytes == round(10.24 * 1_024 * 1_024 * 1_024)
    assert usage.used_bytes == round(6.45 * 1_024 * 1_024 * 1_024)

    assert {:ok, lowercase} = Swap.parse("total = 1g used = 512m free = 512m\n")
    assert lowercase.used_bytes == 512 * 1_024 * 1_024
  end

  test "rejects incomplete output" do
    assert Swap.parse("total = 1G") == {:error, :invalid_output}
  end
end
