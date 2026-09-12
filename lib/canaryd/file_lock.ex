defmodule Canaryd.FileLock do
  @moduledoc false
  alias Canaryd.Duration
  @command_timeout Duration.seconds(5)

  # macOS lockf and Bazel's fcntl locks interoperate. Keep the native lock held
  # across revalidation and removal; do not treat a lock file's existence as busy.
  def with_lock(lock_path, callback, options \\ []) do
    with :ok <- prepare(lock_path, Keyword.get(options, :create, false)),
         {:ok, %{type: :regular} = identity} <- File.lstat(lock_path),
         {:ok, port} <- open_lock_port(lock_path) do
      try do
        receive do
          {^port, {:data, {:eol, "locked"}}} ->
            case File.lstat(lock_path) do
              {:ok, %{type: :regular, inode: inode, major_device: device}}
              when inode == identity.inode and device == identity.major_device ->
                callback.()

              _ ->
                {:error, :lock_unavailable}
            end

          {^port, {:exit_status, 75}} ->
            {:error, :locked}

          {^port, {:exit_status, _}} ->
            {:error, :lock_unavailable}

          {^port, {:data, _}} ->
            {:error, :lock_unavailable}
        after
          @command_timeout -> {:error, :lock_unavailable}
        end
      after
        release_lock(port)
      end
    else
      _ -> {:error, :lock_unavailable}
    end
  end

  defp open_lock_port(lock_path) do
    {:ok,
     Port.open({:spawn_executable, "/usr/bin/lockf"}, [
       :binary,
       :exit_status,
       :stderr_to_stdout,
       {:line, 128},
       args: [
         "-k",
         "-n",
         "-s",
         "-t",
         "0",
         lock_path,
         "/bin/sh",
         "-c",
         "printf 'locked\n'; IFS= read -r release"
       ]
     ])}
  rescue
    _ -> {:error, :unavailable}
  end

  defp release_lock(port) do
    if Port.info(port) do
      Port.command(port, "release\n")

      receive do
        {^port, {:exit_status, _}} -> :ok
      after
        Duration.seconds(1) -> :ok
      end
    end
  rescue
    ArgumentError -> :ok
  after
    if Port.info(port), do: Port.close(port)
  end

  defp prepare(_path, false), do: :ok

  defp prepare(path, true) do
    case File.open(path, [:write, :exclusive]) do
      {:ok, file} -> File.close(file)
      {:error, :eexist} -> :ok
      {:error, _reason} -> {:error, :lock_unavailable}
    end
  end
end
