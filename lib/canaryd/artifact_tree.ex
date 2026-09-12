defmodule Canaryd.ArtifactTree do
  @moduledoc false

  # Remove validated build artifacts incrementally. Only owned directories may
  # change mode: files can be hard-linked to shared caches outside this tree.
  def remove(path, revalidate) do
    with :ok <- revalidate.(),
         {:ok, %{uid: owner}} <- File.lstat(path),
         :ok <- writable_directories(path, owner),
         :ok <- revalidate.(),
         :ok <- remove_tree(path) do
      {:ok, path}
    end
  end

  # Keep only one directory listing at a time, not File.rm_rf's list of every
  # removed path. Remove the output-base lock last while its descriptor is held.
  defp remove_tree(path) do
    case File.lstat(path) do
      {:ok, %{type: :directory}} ->
        with {:ok, entries} <- File.ls(path),
             :ok <- remove_entries(path, Enum.sort_by(entries, &(&1 == "lock"))) do
          File.rmdir(path)
        end

      {:ok, _stat} ->
        File.rm(path)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp remove_entries(path, entries) do
    Enum.reduce_while(entries, :ok, fn entry, :ok ->
      case remove_tree(Path.join(path, entry)) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp writable_directories(path, owner) do
    case File.lstat(path) do
      {:ok, %{type: :directory, uid: ^owner, mode: mode}} ->
        with :ok <- File.chmod(path, Bitwise.bor(mode, 0o700)),
             {:ok, entries} <- File.ls(path) do
          Enum.reduce_while(entries, :ok, fn entry, :ok ->
            case writable_directories(Path.join(path, entry), owner) do
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
end
