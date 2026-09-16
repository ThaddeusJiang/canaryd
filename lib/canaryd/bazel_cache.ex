defmodule Canaryd.BazelCache do
  @moduledoc false

  alias Canaryd.Duration

  @marker_limit 4096
  @command_limit 8 * 1024 * 1024
  @command_timeout Duration.seconds(5)

  def candidates(home) do
    root = Path.join(home, "Library/Caches/bazel")

    if safe_directory?(root, home) do
      for user_root <- children(root),
          String.starts_with?(Path.basename(user_root), "_bazel_"),
          safe_directory?(user_root, home),
          path <- children(user_root),
          valid_candidate?(path, home),
          do: path
    else
      []
    end
    |> Enum.sort()
  end

  def valid_candidate?(path, home) do
    with {:ok, workspace} <- output_base_workspace(path, home) do
      missing_workspace?(workspace, home)
    else
      _ -> false
    end
  end

  # Shared repository caches are also used by bases whose workspaces still
  # exist. Expose identity separately without widening orphan eligibility.
  def valid_output_base?(path, home), do: match?({:ok, _}, output_base_workspace(path, home))

  defp output_base_workspace(path, home) do
    root = Path.join(home, "Library/Caches/bazel")
    user_root = Path.dirname(path)

    with true <- Path.dirname(user_root) == root,
         true <- String.starts_with?(Path.basename(user_root), "_bazel_"),
         true <- safe_directory?(path, home),
         {:ok, %{uid: owner}} <- File.lstat(home),
         {:ok, %{uid: ^owner}} <- File.lstat(path),
         {:ok, workspace} <- read_marker(Path.join(path, "DO_NOT_BUILD_HERE")),
         true <- Path.type(workspace) == :absolute and Path.expand(workspace) == workspace,
         true <- Path.basename(path) == workspace_hash(workspace) do
      {:ok, workspace}
    else
      _ -> false
    end
  end

  def activity(path, %{pids: pids}) do
    server = Path.join(path, "server")

    case File.lstat(server) do
      {:error, :enoent} -> :idle
      {:ok, %{type: :directory}} -> server_activity(server, pids)
      _ -> :unverifiable_cache
    end
  end

  defp server_activity(server, pids) do
    pid_path = Path.join(server, "server.pid.txt")

    case File.lstat(pid_path) do
      {:error, :enoent} ->
        :idle

      {:ok, %{type: :regular}} ->
        with {:ok, value} <- read_marker(pid_path),
             {pid, ""} when pid > 0 <- Integer.parse(value) do
          if MapSet.member?(pids, pid), do: :active_cache, else: :idle
        else
          _ -> :unverifiable_cache
        end

      _ ->
        :unverifiable_cache
    end
  end

  # Read only the small Bazel identity files, never an unbounded cache artifact.
  defp read_marker(path) do
    with {:ok, %{type: :regular, size: size}} when size <= @marker_limit <- File.lstat(path),
         {:ok, content} <- File.open(path, [:read, :binary], &IO.binread(&1, @marker_limit + 1)),
         true <-
           is_binary(content) and byte_size(content) <= @marker_limit and String.valid?(content),
         value = String.trim_trailing(content, "\n"),
         true <- value != "" and not String.contains?(value, ["\n", "\r", <<0>>]) do
      {:ok, value}
    else
      _ -> {:error, :invalid_marker}
    end
  end

  defp workspace_hash(workspace),
    do: :crypto.hash(:md5, workspace) |> Base.encode16(case: :lower)

  defp missing_workspace?(workspace, home) do
    Enum.any?([home, "/private/tmp"], fn root ->
      String.starts_with?(workspace, root <> "/") and
        safe_directory?(root, root) and
        missing_component?(root, Path.relative_to(workspace, root))
    end)
  end

  defp missing_component?(root, relative) do
    relative
    |> Path.split()
    |> Enum.reduce_while(root, fn component, parent ->
      path = Path.join(parent, component)

      case File.lstat(path) do
        {:error, :enoent} -> {:halt, true}
        {:ok, %{type: :directory}} -> {:cont, path}
        _ -> {:halt, false}
      end
    end)
    |> Kernel.==(true)
  end

  defp safe_directory?(path, root) do
    if path == root or String.starts_with?(path, root <> "/") do
      case File.lstat(path) do
        {:ok, %{type: :directory}} -> path == root or safe_directory?(Path.dirname(path), root)
        _ -> false
      end
    else
      false
    end
  end

  defp children(root) do
    case File.ls(root) do
      {:ok, entries} -> Enum.map(entries, &Path.join(root, &1))
      _ -> []
    end
  end

  # Bazel runfiles directories can be read-only. Change only directory modes;
  # regular artifacts may be hard-linked to caches that must remain unchanged.
  def remove(path, revalidate) do
    with_lock(path, fn -> Canaryd.ArtifactTree.remove(path, revalidate) end)
  end

  def with_lock(path, callback) do
    case Canaryd.FileLock.with_lock(Path.join(path, "lock"), callback) do
      {:error, :locked} -> {:skip, :active_cache}
      {:error, :lock_unavailable} -> {:skip, :unverifiable_cache}
      result -> result
    end
  end

  def scan_activity(runner \\ &command/2) do
    with {:ok, processes} <- runner.("/bin/ps", ["-axo", "pid="]),
         {:ok, pids} <- parse_pids(processes),
         true <- MapSet.size(pids) > 0 do
      {:ok, %{pids: pids}}
    else
      _ -> {:error, :unavailable}
    end
  end

  defp parse_pids(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.reduce_while({:ok, MapSet.new()}, fn line, {:ok, pids} ->
      case Integer.parse(String.trim(line)) do
        {pid, ""} when pid > 0 -> {:cont, {:ok, MapSet.put(pids, pid)}}
        _ -> {:halt, {:error, :unavailable}}
      end
    end)
  end

  # Bound both latency and captured output: a failed inspection is never proof
  # that a cache is idle. No command lines enter event history.
  def command(executable, args) do
    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: args
      ])

    deadline = System.monotonic_time(:millisecond) + @command_timeout

    try do
      receive_output(port, [], 0, deadline)
    after
      if Port.info(port), do: Port.close(port)
    end
  rescue
    _ -> {:error, :unavailable}
  end

  defp receive_output(port, chunks, bytes, deadline) do
    receive do
      {^port, {:data, chunk}} when bytes + byte_size(chunk) <= @command_limit ->
        receive_output(port, [chunk | chunks], bytes + byte_size(chunk), deadline)

      {^port, {:data, _chunk}} ->
        {:error, :output_limit}

      {^port, {:exit_status, 0}} ->
        {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}

      {^port, {:exit_status, _status}} ->
        {:error, :unavailable}
    after
      max(deadline - System.monotonic_time(:millisecond), 0) -> {:error, :timeout}
    end
  end
end
