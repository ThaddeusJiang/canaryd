defmodule Canaryd.ArtifactTreeTest do
  use ExUnit.Case, async: true

  alias Canaryd.ArtifactTree

  setup do
    root = "/private/tmp/canaryd-artifact-tree-#{System.unique_integer([:positive])}"
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    %{root: root}
  end

  test "permission preparation preserves directory age for final revalidation", %{root: root} do
    for mode <- [0o755, 0o555] do
      path = Path.join(root, Integer.to_string(mode))
      File.mkdir_p!(path)
      File.write!(Path.join(path, "artifact"), "output")
      File.chmod!(path, mode)
      File.touch!(path, {{2020, 1, 1}, {0, 0, 0}})

      assert {:ok, ^path} =
               ArtifactTree.remove(path, fn ->
                 assert File.stat!(path).mtime == {{2020, 1, 1}, {0, 0, 0}}
                 :ok
               end)
    end
  end

  test "read-only cleanup leaves external hard links and symlink targets intact", %{root: root} do
    source = Path.join(root, "source")
    File.write!(source, "keep")
    File.chmod!(source, 0o444)
    before = File.stat!(source)
    path = Path.join(root, "cache")
    File.mkdir_p!(path)
    File.ln!(source, Path.join(path, "shared"))
    File.ln_s!(source, Path.join(path, "linked"))
    File.chmod!(path, 0o555)

    assert {:ok, ^path} = ArtifactTree.remove(path, fn -> :ok end)
    assert File.read!(source) == "keep"
    assert File.stat!(source).mode == before.mode
    assert File.stat!(source).mtime == before.mtime
  end

  test "a changed child still blocks removal after directory permission preparation", %{
    root: root
  } do
    path = Path.join(root, "cache")
    File.mkdir_p!(path)
    child = Path.join(path, "artifact")
    File.write!(child, "output")
    File.touch!(child, {{2020, 1, 1}, {0, 0, 0}})
    File.chmod!(path, 0o555)

    assert {:skip, :recent} =
             ArtifactTree.remove(path, fn ->
               if Process.get(:artifact_prepared) do
                 if File.stat!(child).mtime != {{2020, 1, 1}, {0, 0, 0}},
                   do: {:skip, :recent},
                   else: :ok
               else
                 Process.put(:artifact_prepared, true)
                 File.touch!(child)
                 :ok
               end
             end)

    assert File.read!(child) == "output"
  end

  test "a filesystem mounted during either traversal is never entered", %{root: root} do
    for stage <- [:prepare, :remove] do
      path = Path.join(root, Atom.to_string(stage))
      mounted = Path.join(path, "volume")
      File.mkdir_p!(mounted)
      child = Path.join(mounted, "keep")
      File.write!(child, "external data")
      File.chmod!(mounted, 0o555)
      original_mode = File.stat!(mounted).mode
      Process.put(:tree_validation_count, 0)

      revalidate = fn ->
        Process.put(:tree_validation_count, Process.get(:tree_validation_count) + 1)
        :ok
      end

      stat_reader = fn entry ->
        {:ok, stat} = File.lstat(entry)
        mounted_now = stage == :prepare or Process.get(:tree_validation_count) == 2

        if entry == mounted and mounted_now,
          do: {:ok, %{stat | major_device: stat.major_device + 1}},
          else: {:ok, stat}
      end

      assert {:error, :cross_filesystem} =
               ArtifactTree.remove(path, revalidate, stat_reader: stat_reader)

      assert File.read!(child) == "external data"
      if stage == :prepare, do: assert(File.stat!(mounted).mode == original_mode)
      File.chmod!(mounted, 0o755)
    end
  end
end
