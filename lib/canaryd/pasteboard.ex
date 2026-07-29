defmodule Canaryd.Pasteboard do
  @moduledoc """
  Runs a reversible probe transaction on a macOS pasteboard.
  """

  @probe_script """
  ObjC.import("AppKit")
  const durationScale = 1000

  function run(argv) {
    const marker = argv[0]
    const waitDuration = Number(argv[1])
    const pasteboardName = argv[2]
    const pasteboard = pasteboardName === ""
      ? $.NSPasteboard.generalPasteboard
      : $.NSPasteboard.pasteboardWithName(pasteboardName)
    const savedItems = $.NSMutableArray.array
    const existingItems = ObjC.unwrap(pasteboard.pasteboardItems) || []

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

    pasteboard.clearContents

    if (!pasteboard.setStringForType(marker, $.NSPasteboardTypeString)) {
      throw new Error("Cannot write probe marker")
    }

    const markerChangeCount = Number(pasteboard.changeCount)
    delay(waitDuration / durationScale)

    if (Number(pasteboard.changeCount) === markerChangeCount) {
      pasteboard.clearContents

      if (savedItems.count > 0 && !pasteboard.writeObjects(savedItems)) {
        throw new Error("Cannot restore pasteboard data")
      }
    }
  }
  """

  @doc """
  Writes a marker and restores the previous items when no newer write occurs.
  The wait duration uses milliseconds.
  """
  def probe(marker, wait_duration, options \\ []) do
    runner = Keyword.get(options, :runner, &System.cmd/3)
    pasteboard_name = Keyword.get(options, :pasteboard_name, "")

    args = [
      "-l",
      "JavaScript",
      "-e",
      @probe_script,
      marker,
      Integer.to_string(wait_duration),
      pasteboard_name
    ]

    case runner.("osascript", args, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {_output, _status} -> {:error, :pasteboard_transaction_failed}
    end
  end
end
