defmodule Canaryd.PasteboardTest do
  use ExUnit.Case, async: false

  alias Canaryd.{Duration, Pasteboard}

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

  setup do
    root =
      Path.join(System.tmp_dir!(), "canaryd-pasteboard-#{System.unique_integer([:positive])}")

    text_path = Path.join(root, "text")
    custom_path = Path.join(root, "custom")

    File.mkdir_p!(root)
    File.write!(text_path, "replayed text")
    File.write!(custom_path, "replayed custom data")
    on_exit(fn -> File.rm_rf(root) end)

    %{contents: [{"public.utf8-plain-text", text_path}, {"com.canaryd.test", custom_path}]}
  end

  test "replays every stored type and restores the previous pasteboard item", %{
    contents: contents
  } do
    pasteboard_name = unique_pasteboard_name()
    write_item(pasteboard_name, "original text", "original custom data")

    replay =
      Task.async(fn ->
        Pasteboard.replay(contents, Duration.milliseconds(500), pasteboard_name: pasteboard_name)
      end)

    assert eventually(fn ->
             read_item(pasteboard_name) == "replayed text\nreplayed custom data"
           end)

    assert Task.await(replay) == :ok
    assert read_item(pasteboard_name) == "original text\noriginal custom data"
  end

  test "keeps newer content when another writer changes the pasteboard", %{contents: contents} do
    pasteboard_name = unique_pasteboard_name()
    write_item(pasteboard_name, "original text", "original custom data")

    replay =
      Task.async(fn ->
        Pasteboard.replay(contents, Duration.milliseconds(500), pasteboard_name: pasteboard_name)
      end)

    assert eventually(fn ->
             read_item(pasteboard_name) == "replayed text\nreplayed custom data"
           end)

    write_item(pasteboard_name, "new text", "new custom data")

    assert Task.await(replay) == :ok
    assert read_item(pasteboard_name) == "new text\nnew custom data"
  end

  test "returns a failure when the pasteboard command fails", %{contents: contents} do
    runner = fn _command, _args, _options -> {"command failed", 1} end

    assert Pasteboard.replay(contents, Duration.milliseconds(10), runner: runner) ==
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
      Process.sleep(Duration.milliseconds(10))
      eventually(fun, attempts - 1)
    end
  end
end
