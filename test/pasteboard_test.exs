defmodule Canaryd.PasteboardTest do
  use ExUnit.Case, async: false

  alias Canaryd.Pasteboard

  @write_script """
  ObjC.import("AppKit")

  function run(argv) {
    const pasteboard = $.NSPasteboard.pasteboardWithName(argv[0])
    const item = $.NSPasteboardItem.alloc.init

    item.setStringForType(argv[1], $.NSPasteboardTypeString)
    item.setStringForType(argv[2], "com.canaryd.test")
    pasteboard.clearContents
    pasteboard.writeObjects($.NSArray.arrayWithObject(item))
  }
  """

  @read_script """
  ObjC.import("AppKit")

  function run(argv) {
    const pasteboard = $.NSPasteboard.pasteboardWithName(argv[0])
    const item = ObjC.unwrap(pasteboard.pasteboardItems)[0]

    if (!item) {
      return ""
    }

    const text = ObjC.unwrap(item.stringForType($.NSPasteboardTypeString)) || ""
    const custom = ObjC.unwrap(item.stringForType("com.canaryd.test")) || ""
    return text + "\\n" + custom
  }
  """

  test "restores every saved type when the probe marker is unchanged" do
    pasteboard_name = unique_pasteboard_name()
    write_item(pasteboard_name, "original text", "original custom data")

    assert Pasteboard.probe("probe marker", 10, pasteboard_name: pasteboard_name) == :ok
    assert read_item(pasteboard_name) == "original text\noriginal custom data"
  end

  test "keeps newer content when another writer changes the pasteboard" do
    pasteboard_name = unique_pasteboard_name()
    marker = "probe marker"
    write_item(pasteboard_name, "original text", "original custom data")

    probe =
      Task.async(fn ->
        Pasteboard.probe(marker, 500, pasteboard_name: pasteboard_name)
      end)

    assert eventually(fn -> read_item(pasteboard_name) == marker end)
    write_item(pasteboard_name, "new text", "new custom data")

    assert Task.await(probe) == :ok
    assert read_item(pasteboard_name) == "new text\nnew custom data"
  end

  test "returns a failure when the pasteboard command fails" do
    runner = fn _command, _args, _options -> {"command failed", 1} end

    assert Pasteboard.probe("probe marker", 10, runner: runner) ==
             {:error, :pasteboard_transaction_failed}
  end

  defp unique_pasteboard_name do
    "com.canaryd.test.#{System.unique_integer([:positive])}"
  end

  defp write_item(pasteboard_name, text, custom) do
    run_jxa(@write_script, [pasteboard_name, text, custom])
  end

  defp read_item(pasteboard_name) do
    run_jxa(@read_script, [pasteboard_name])
  end

  defp run_jxa(script, args) do
    {output, 0} =
      System.cmd(
        "osascript",
        ["-l", "JavaScript", "-e", script] ++ args,
        stderr_to_stdout: true
      )

    String.trim_trailing(output)
  end

  defp eventually(fun, attempts \\ 50)

  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end
end
