defmodule Canaryd.CleanClipHistoryTest do
  use ExUnit.Case, async: true

  alias Canaryd.CleanClipHistory

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "canaryd-cleanclip-history-#{System.unique_integer([:positive])}"
      )

    store_path = Path.join(root, "Storage.sqlite")
    contents_dir = Path.join(root, "HistoryItemContents")
    File.mkdir_p!(contents_dir)

    run_sql!(store_path, """
    CREATE TABLE ZHISTORYITEM (
      Z_PK INTEGER PRIMARY KEY,
      ZNUMBEROFCOPIES INTEGER,
      ZLASTCOPIEDAT TIMESTAMP,
      ZTITLE VARCHAR
    );
    CREATE TABLE ZHISTORYITEMCONTENT (
      Z_PK INTEGER PRIMARY KEY,
      ZITEM INTEGER,
      ZPERSISTENTID VARCHAR,
      ZTYPE VARCHAR
    );
    """)

    on_exit(fn -> File.rm_rf(root) end)

    %{store_path: store_path, contents_dir: contents_dir}
  end

  test "reads every content type from the latest non-probe history item", context do
    insert_item(context, 1, 1, 1, "older", [{1, "OLD", "public.utf8-plain-text", "old"}])

    insert_item(context, 2, 9, 3, "canaryd-probe-388", [
      {2, "PROBE", "public.utf8-plain-text", "canaryd-probe-388"}
    ])

    contents = [
      {3, "NEW-TEXT", "public.utf8-plain-text", "latest"},
      {4, "NEW-CUSTOM", "com.canaryd.test", <<0, 1, 2, 3>>}
    ]

    insert_item(context, 3, 1, 2, "latest", contents)

    assert {:ok, item} =
             CleanClipHistory.latest(
               store_path: context.store_path,
               contents_dir: context.contents_dir
             )

    assert item.id == 3
    assert item.copies == 1
    assert item.baseline == 3.0

    assert item.contents == [
             {"public.utf8-plain-text",
              content_path(context, "NEW-TEXT", "public.utf8-plain-text")},
             {"com.canaryd.test", content_path(context, "NEW-CUSTOM", "com.canaryd.test")}
           ]
  end

  test "accepts a new history row with the same types and bytes", context do
    insert_item(context, 7, 1, 1, "latest", [
      {1, "TEXT-A", "public.utf8-plain-text", "latest"},
      {2, "CUSTOM-A", "com.canaryd.test", <<0, 1, 2, 3>>}
    ])

    assert {:ok, item} =
             CleanClipHistory.latest(
               store_path: context.store_path,
               contents_dir: context.contents_dir
             )

    insert_item(context, 8, 1, 2, "latest", [
      {3, "TEXT-B", "public.utf8-plain-text", "latest"},
      {4, "CUSTOM-B", "com.canaryd.test", <<0, 1, 2, 3>>}
    ])

    assert CleanClipHistory.duplicate_recorded?(item,
             store_path: context.store_path,
             contents_dir: context.contents_dir
           ) == {:ok, true}
  end

  test "accepts a duplicate when CleanClip omits one secondary content file", context do
    insert_item(context, 7, 1, 1, "latest", [
      {1, "TEXT-A", "public.utf8-plain-text", "latest"},
      {2, "RTF-A", "public.rtf", "rich text"}
    ])

    assert {:ok, item} =
             CleanClipHistory.latest(
               store_path: context.store_path,
               contents_dir: context.contents_dir
             )

    insert_item(context, 8, 1, 2, "latest", [
      {3, "TEXT-B", "public.utf8-plain-text", "latest"},
      {4, "RTF-B", "public.rtf", "rich text"}
    ])

    File.rm!(content_path(context, "RTF-B", "public.rtf"))

    assert CleanClipHistory.duplicate_recorded?(item,
             store_path: context.store_path,
             contents_dir: context.contents_dir
           ) == {:ok, true}
  end

  test "rejects a new history row with different content", context do
    insert_item(context, 7, 1, 1, "latest", [
      {1, "TEXT-A", "public.utf8-plain-text", "latest"}
    ])

    assert {:ok, item} =
             CleanClipHistory.latest(
               store_path: context.store_path,
               contents_dir: context.contents_dir
             )

    insert_item(context, 8, 1, 2, "different", [
      {2, "TEXT-B", "public.utf8-plain-text", "different"}
    ])

    assert CleanClipHistory.duplicate_recorded?(item,
             store_path: context.store_path,
             contents_dir: context.contents_dir
           ) == {:ok, false}
  end

  test "accepts an increased copy count on the selected row", context do
    insert_item(context, 7, 1, 1, "latest", [
      {1, "TEXT", "public.utf8-plain-text", "latest"}
    ])

    assert {:ok, item} =
             CleanClipHistory.latest(
               store_path: context.store_path,
               contents_dir: context.contents_dir
             )

    run_sql!(context.store_path, """
    UPDATE ZHISTORYITEM SET ZNUMBEROFCOPIES = 2, ZLASTCOPIEDAT = 2 WHERE Z_PK = 7;
    """)

    assert CleanClipHistory.duplicate_recorded?(item,
             store_path: context.store_path,
             contents_dir: context.contents_dir
           ) == {:ok, true}
  end

  test "skips an incomplete latest item and reads the previous replayable item", context do
    insert_item(context, 1, 1, 1, "replayable", [
      {1, "TEXT-A", "public.utf8-plain-text", "replayable"}
    ])

    insert_item(context, 2, 1, 2, "incomplete", [
      {2, "TEXT-B", "public.utf8-plain-text", "incomplete"}
    ])

    File.rm!(content_path(context, "TEXT-B", "public.utf8-plain-text"))

    assert {:ok, item} =
             CleanClipHistory.latest(
               store_path: context.store_path,
               contents_dir: context.contents_dir
             )

    assert item.id == 1
    assert item.baseline == 2.0
  end

  test "fails when no history item content is available", context do
    run_sql!(context.store_path, """
    INSERT INTO ZHISTORYITEM VALUES (1, 1, 1, 'latest');
    INSERT INTO ZHISTORYITEMCONTENT VALUES (1, 1, 'MISSING', 'public.utf8-plain-text');
    """)

    assert CleanClipHistory.latest(
             store_path: context.store_path,
             contents_dir: context.contents_dir
           ) == {:error, :history_content_unreadable}
  end

  defp insert_item(context, id, copies, copied_at, title, contents) do
    run_sql!(context.store_path, """
    INSERT INTO ZHISTORYITEM VALUES (#{id}, #{copies}, #{copied_at}, '#{title}');
    """)

    Enum.each(contents, fn {content_id, persistent_id, type, data} ->
      run_sql!(context.store_path, """
      INSERT INTO ZHISTORYITEMCONTENT VALUES (#{content_id}, #{id}, '#{persistent_id}', '#{type}');
      """)

      File.write!(content_path(context, persistent_id, type), data)
    end)
  end

  defp content_path(context, persistent_id, type) do
    Path.join(context.contents_dir, "#{persistent_id}.#{type}")
  end

  defp run_sql!(store_path, sql) do
    {output, 0} = System.cmd("sqlite3", [store_path, sql], stderr_to_stdout: true)
    output
  end
end
