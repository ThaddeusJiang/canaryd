defmodule Canaryd.ArtifactTree do
  @moduledoc false

  # Remove validated build artifacts incrementally. Only owned directories may
  # change mode: files can be hard-linked to shared caches outside this tree.
  def remove(path, revalidate, options \\ []) do
    stat_reader = Keyword.get(options, :stat_reader, &File.lstat/1)

    with :ok <- revalidate.(),
         {:ok, %{uid: owner, major_device: device}} <- stat_reader.(path),
         :ok <- writable_directories(path, owner, device, stat_reader),
         :ok <- revalidate.(),
         :ok <- remove_tree(path, device, stat_reader) do
      {:ok, path}
    end
  end

  # Keep only one directory listing at a time, not File.rm_rf's list of every
  # removed path. Remove the output-base lock last while its descriptor is held.
  defp remove_tree(path, device, stat_reader) do
    case stat_reader.(path) do
      {:ok, %{major_device: other}} when other != device ->
        {:error, :cross_filesystem}

      {:ok, %{type: :directory}} ->
        with {:ok, entries} <- File.ls(path),
             :ok <-
               remove_entries(path, Enum.sort_by(entries, &(&1 == "lock")), device, stat_reader) do
          File.rmdir(path)
        end

      {:ok, _stat} ->
        File.rm(path)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp remove_entries(path, entries, device, stat_reader) do
    Enum.reduce_while(entries, :ok, fn entry, :ok ->
      case remove_tree(Path.join(path, entry), device, stat_reader) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp writable_directories(path, owner, device, stat_reader) do
    case stat_reader.(path) do
      {:ok, %{major_device: other}} when other != device ->
        {:error, :cross_filesystem}

      {:ok, %{type: :directory, uid: ^owner} = stat} ->
        with :ok <- make_writable(path, stat),
             {:ok, entries} <- File.ls(path) do
          Enum.reduce_while(entries, :ok, fn entry, :ok ->
            case writable_directories(Path.join(path, entry), owner, device, stat_reader) do
              :ok -> {:cont, :ok}
              error -> {:halt, error}
            end
          end)
        end

      {:ok, %{type: :directory}} ->
        {:error, :unexpected_owner}

      {:ok, _stat} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp make_writable(path, stat) do
    if Bitwise.band(stat.mode, 0o700) == 0o700 do
      :ok
    else
      # OTP's File.chmod/2 can refresh directory mtime. Native chmod changes
      # only permissions, preserving both old age and concurrent timestamp
      # updates for revalidation. -h avoids following a replaced final symlink.
      case Canaryd.BazelCache.command("/bin/chmod", ["-h", "u+rwx", path]) do
        {:ok, _output} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end
end
