defmodule Canaryd.Pasteboard do
  @moduledoc """
  Replays a CleanClip history item in a reversible pasteboard transaction.
  """

  @replay_script """
  ObjC.import("AppKit")

  function run(argv) {
    const waitDuration = Number(argv[0])
    const pasteboardName = argv[1]
    const pasteboard = pasteboardName === ""
      ? $.NSPasteboard.generalPasteboard
      : $.NSPasteboard.pasteboardWithName(pasteboardName)
    const savedItems = $.NSMutableArray.array
    const existingItems = ObjC.unwrap(pasteboard.pasteboardItems) || []
    const replayedItem = $.NSPasteboardItem.alloc.init

    existingItems.forEach(function(item) {
      const savedItem = $.NSPasteboardItem.alloc.init
      const types = ObjC.unwrap(item.types) || []

      types.forEach(function(type) {
        const data = item.dataForType(type)

        if (!data || !savedItem.setDataForType(data, type)) {
          throw new Error("Cannot snapshot pasteboard data")
        }
      })

      savedItems.addObject(savedItem)
    })

    for (let index = 2; index < argv.length; index += 2) {
      const type = argv[index]
      const path = argv[index + 1]
      const data = $.NSData.dataWithContentsOfFile(path)

      if (!data || !replayedItem.setDataForType(data, type)) {
        throw new Error("Cannot read CleanClip history content")
      }
    }

    pasteboard.clearContents

    if (!pasteboard.writeObjects($.NSArray.arrayWithObject(replayedItem))) {
      throw new Error("Cannot replay CleanClip history item")
    }

    const replayChangeCount = Number(pasteboard.changeCount)
    delay(waitDuration / 1000)

    if (Number(pasteboard.changeCount) === replayChangeCount) {
      pasteboard.clearContents

      if (savedItems.count > 0 && !pasteboard.writeObjects(savedItems)) {
        throw new Error("Cannot restore pasteboard data")
      }
    }
  }
  """

  @doc """
  Replays every stored type and restores the previous pasteboard when unchanged.
  The wait duration uses milliseconds.
  """
  def replay(contents, wait_duration, options \\ []) do
    runner = Keyword.get(options, :runner, &System.cmd/3)
    pasteboard_name = Keyword.get(options, :pasteboard_name, "")

    content_args = Enum.flat_map(contents, fn {type, path} -> [type, path] end)

    args =
      [
        "-l",
        "JavaScript",
        "-e",
        @replay_script,
        Integer.to_string(wait_duration),
        pasteboard_name
      ] ++ content_args

    case runner.("osascript", args, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {_output, _status} -> {:error, :pasteboard_transaction_failed}
    end
  end
end
