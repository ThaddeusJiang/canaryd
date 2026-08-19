defmodule Canaryd.CleanClipHistory do
  @moduledoc false

  alias Canaryd.Paths

  @primary_types [
    "public.utf8-plain-text",
    "public.text",
    "public.png",
    "public.tiff",
    "public.file-url",
    "public.url",
    "public.rtf"
  ]

  @latest_item_query """
  SELECT Z_PK, ZNUMBEROFCOPIES,
         (SELECT COALESCE(MAX(ZLASTCOPIEDAT), 0) FROM ZHISTORYITEM)
  FROM ZHISTORYITEM
  WHERE ZTITLE IS NULL OR ZTITLE NOT LIKE 'canaryd-probe-%'
  ORDER BY ZLASTCOPIEDAT DESC
  LIMIT 100;
  """

  def latest(options \\ []) do
    store_path = Keyword.get(options, :store_path, Paths.clean_clip_store_path())
    contents_dir = Keyword.get(options, :contents_dir, Paths.clean_clip_history_dir())

    case query(store_path, @latest_item_query, 3) do
      {:ok, []} -> {:error, :history_empty}
      {:ok, rows} -> first_replayable(rows, store_path, contents_dir)
      {:error, reason} -> {:error, reason}
    end
  end

  defp first_replayable(rows, store_path, contents_dir) do
    Enum.reduce_while(rows, {:error, :history_content_unreadable}, fn row, _result ->
      case replayable_item(row, store_path, contents_dir) do
        {:ok, item} -> {:halt, {:ok, item}}
        {:error, :history_content_unreadable} -> {:cont, {:error, :history_content_unreadable}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp replayable_item([id, copies, baseline], store_path, contents_dir) do
    with {id, ""} <- Integer.parse(id),
         {copies, ""} <- Integer.parse(copies),
         {baseline, ""} <- Float.parse(baseline),
         {:ok, content_rows} <- query(store_path, contents_query(id), 2),
         {:ok, contents} <- content_paths(content_rows, contents_dir) do
      {:ok, %{id: id, copies: copies, baseline: baseline, contents: contents}}
    else
      {:error, reason} -> {:error, reason}
      _invalid_data -> {:error, :history_store_unreadable}
    end
  end

  def duplicate_recorded?(item, options \\ []) do
    store_path = Keyword.get(options, :store_path, Paths.clean_clip_store_path())
    contents_dir = Keyword.get(options, :contents_dir, Paths.clean_clip_history_dir())

    with {:ok, expected_signature} <- content_signature(item.contents),
         {:ok, candidates} <- query(store_path, candidates_query(item.baseline), 2) do
      {:ok,
       Enum.any?(candidates, fn candidate ->
         candidate_matches?(candidate, item, expected_signature, store_path, contents_dir)
       end)}
    end
  end

  defp candidates_query(baseline) do
    """
    SELECT Z_PK, ZNUMBEROFCOPIES
    FROM ZHISTORYITEM
    WHERE ZLASTCOPIEDAT > #{Float.to_string(baseline)}
      AND (ZTITLE IS NULL OR ZTITLE NOT LIKE 'canaryd-probe-%')
    ORDER BY ZLASTCOPIEDAT DESC;
    """
  end

  defp candidate_matches?([id, copies], item, expected_signature, store_path, contents_dir) do
    with {id, ""} <- Integer.parse(id),
         {copies, ""} <- Integer.parse(copies),
         true <- id != item.id or copies > item.copies,
         {:ok, content_rows} <- query(store_path, contents_query(id), 2),
         contents <- available_content_paths(content_rows, contents_dir),
         {:ok, signature} <- content_signature(contents) do
      matching_content?(expected_signature, signature)
    else
      _no_match -> false
    end
  end

  defp contents_query(id) do
    """
    SELECT ZPERSISTENTID, ZTYPE
    FROM ZHISTORYITEMCONTENT
    WHERE ZITEM = #{id}
    ORDER BY Z_PK;
    """
  end

  defp query(store_path, sql, field_count) do
    case System.cmd(
           "sqlite3",
           ["-readonly", "-noheader", "-separator", "\t", store_path, sql],
           stderr_to_stdout: true
         ) do
      {output, 0} -> parse_rows(output, field_count)
      {_output, _status} -> {:error, :history_store_unreadable}
    end
  end

  defp parse_rows(output, field_count) do
    rows =
      output
      |> String.split("\n", trim: true)
      |> Enum.map(&String.split(&1, "\t"))

    if Enum.all?(rows, &(length(&1) == field_count)),
      do: {:ok, rows},
      else: {:error, :history_store_unreadable}
  end

  defp content_paths([], _contents_dir), do: {:error, :history_content_unreadable}

  defp content_paths(rows, contents_dir) do
    contents =
      Enum.map(rows, fn [persistent_id, type] ->
        filename = "#{persistent_id}.#{type}"
        {type, Path.join(contents_dir, filename), filename}
      end)

    if Enum.all?(contents, fn {_type, path, filename} ->
         Path.basename(filename) == filename and File.regular?(path)
       end) do
      {:ok, Enum.map(contents, fn {type, path, _filename} -> {type, path} end)}
    else
      {:error, :history_content_unreadable}
    end
  end

  defp available_content_paths(rows, contents_dir) do
    rows
    |> Enum.map(fn [persistent_id, type] ->
      filename = "#{persistent_id}.#{type}"
      {type, Path.join(contents_dir, filename), filename}
    end)
    |> Enum.filter(fn {_type, path, filename} ->
      Path.basename(filename) == filename and File.regular?(path)
    end)
    |> Enum.map(fn {type, path, _filename} -> {type, path} end)
  end

  defp matching_content?(expected, candidate) do
    expected_by_type = Enum.group_by(expected, &elem(&1, 0), &elem(&1, 1))
    candidate_by_type = Enum.group_by(candidate, &elem(&1, 0), &elem(&1, 1))

    shared_types =
      @primary_types
      |> Enum.filter(
        &(Map.has_key?(expected_by_type, &1) and Map.has_key?(candidate_by_type, &1))
      )
      |> case do
        [] ->
          Map.keys(expected_by_type) --
            (Map.keys(expected_by_type) -- Map.keys(candidate_by_type))

        primary_types ->
          primary_types
      end

    shared_types != [] and
      Enum.all?(shared_types, fn type ->
        Enum.sort(expected_by_type[type]) == Enum.sort(candidate_by_type[type])
      end)
  end

  defp content_signature(contents) do
    contents
    |> Enum.reduce_while({:ok, []}, fn {type, path}, {:ok, signature} ->
      case file_signature(path) do
        {:ok, file_signature} -> {:cont, {:ok, [{type, file_signature} | signature]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, signature} -> {:ok, Enum.sort(signature)}
      error -> error
    end
  end

  defp file_signature(path) do
    case File.open(path, [:read, :binary]) do
      {:ok, file} ->
        try do
          digest(file, :erlang.md5_init())
        after
          File.close(file)
        end

      {:error, _reason} ->
        {:error, :history_content_unreadable}
    end
  end

  defp digest(file, context) do
    case IO.binread(file, 64 * 1024) do
      :eof -> {:ok, :erlang.md5_final(context)}
      data when is_binary(data) -> digest(file, :erlang.md5_update(context, data))
      {:error, _reason} -> {:error, :history_content_unreadable}
    end
  end
end
