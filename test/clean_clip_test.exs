defmodule Canaryd.Apps.CleanClipTest do
  use ExUnit.Case, async: true

  alias Canaryd.Apps.CleanClip
  alias Canaryd.Duration

  test "replays the latest history item and succeeds when CleanClip records a duplicate" do
    caller = self()
    item = %{id: 7, copies: 1, contents: [{"public.utf8-plain-text", "/tmp/latest"}]}
    contents = item.contents

    assert CleanClip.probe(
             history_reader: fn -> {:ok, item} end,
             pasteboard_replayer: fn replayed_contents, wait_duration ->
               send(caller, {:replayed, replayed_contents, wait_duration})
               :ok
             end,
             duplicate_reader: fn ^item -> {:ok, true} end
           ) == :ok

    assert_received {:replayed, ^contents, wait_duration}
    assert wait_duration == Duration.seconds(4)
  end

  test "fails when CleanClip does not record another copy" do
    item = %{id: 7, copies: 1, contents: [{"public.utf8-plain-text", "/tmp/latest"}]}

    assert CleanClip.probe(
             history_reader: fn -> {:ok, item} end,
             pasteboard_replayer: fn _contents, _wait_duration -> :ok end,
             duplicate_reader: fn ^item -> {:ok, false} end
           ) == {:fail, :no_duplicate_history_item}
  end
end
