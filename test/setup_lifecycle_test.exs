defmodule Canaryd.SetupLifecycleTest do
  use ExUnit.Case, async: false

  alias Canaryd.{CLI, Paths, Setup}
  import ExUnit.CaptureIO

  setup do
    original_home = System.get_env("HOME")
    home = Path.join(System.tmp_dir!(), "canaryd-setup-#{System.unique_integer([:positive])}")
    System.put_env("HOME", home)

    on_exit(fn ->
      if original_home, do: System.put_env("HOME", original_home), else: System.delete_env("HOME")
      File.rm_rf!(home)
    end)

    state =
      start_supervised!({Agent, fn -> %{loaded: MapSet.new(), calls: [], failures: %{}} end})

    runner = fn "launchctl", args, [stderr_to_stdout: true] ->
      Agent.get_and_update(state, &launchctl(args, &1))
    end

    %{state: state, options: [runner: runner, ensure_notification_helper: fn -> :ok end]}
  end

  test "custom schedule is persisted and repeated installation stays idempotent", %{
    options: options,
    state: state
  } do
    {:ok, config} =
      Canaryd.Config.resolve([check_interval: "2m", cleanup_at: "03:45", build_retention: "48h"],
        env: %{}
      )

    options = Keyword.put(options, :config, config)
    assert :ok = Setup.install(options)

    paths =
      for label <- Setup.labels(), do: Path.join(Paths.launch_agents_dir(), label <> ".plist")

    [check, clean] = Enum.map(paths, &File.read!/1)
    assert check =~ "<integer>120</integer>"
    assert clean =~ "<integer>3</integer>"
    assert clean =~ "<integer>45</integer>"
    assert clean =~ "<string>48h</string>"
    for path <- paths, do: assert({_output, 0} = System.cmd("plutil", ["-lint", path]))
    before = Agent.get(state, & &1.calls)
    assert :ok = Setup.install(options)
    after_calls = Agent.get(state, & &1.calls)

    assert Enum.count(before, fn {verb, _} -> verb == "bootstrap" end) ==
             Enum.count(after_calls, fn {verb, _} -> verb == "bootstrap" end)
  end

  test "repeated start preserves loaded agents and plist metadata", %{
    options: options,
    state: state
  } do
    start = fn -> Setup.install(options) end
    assert capture_io(fn -> CLI.main(["start"], start: start) end) =~ "monitoring started"
    assert take_calls(state) == Enum.map(Setup.labels(), &{"bootstrap", &1})
    before = plist_metadata()

    assert capture_io(fn -> CLI.main(["start"], start: start) end) =~ "monitoring started"
    assert take_calls(state) == []
    assert plist_metadata(touch?: false) == before
  end

  test "reloads only the agent whose configuration changed", %{options: options, state: state} do
    assert :ok = Setup.install(options)
    take_calls(state)
    [label, _] = Setup.labels()
    File.write!(plist_path(label), "outdated configuration")
    before = plist_metadata()

    assert :ok = Setup.install(options)
    assert take_calls(state) == [{"bootout", label}, {"bootstrap", label}]
    assert File.read!(plist_path(label)) =~ "<integer>300</integer>"
    assert List.last(plist_metadata(touch?: false)) == List.last(before)
  end

  test "loads a missing job without rewriting its unchanged plist", %{
    options: options,
    state: state
  } do
    assert :ok = Setup.install(options)
    take_calls(state)
    [_, label] = Setup.labels()
    Agent.update(state, &%{&1 | loaded: MapSet.delete(&1.loaded, label)})
    before = plist_metadata()

    assert :ok = Setup.install(options)
    assert take_calls(state) == [{"bootstrap", label}]
    assert plist_metadata(touch?: false) == before
  end

  test "failed unload leaves the old configuration available for a retry", %{
    options: options,
    state: state
  } do
    assert :ok = Setup.install(options)
    take_calls(state)
    [label, _] = Setup.labels()
    File.write!(plist_path(label), "old configuration")
    Agent.update(state, &%{&1 | failures: %{{"bootout", label} => {"unload failed", 1}}})

    assert {:error, "unload failed"} = Setup.install(options)
    assert take_calls(state) == [{"bootout", label}]
    assert File.read!(plist_path(label)) == "old configuration"

    Agent.update(state, &%{&1 | failures: %{}})
    assert :ok = Setup.install(options)
    assert take_calls(state) == [{"bootout", label}, {"bootstrap", label}]
  end

  test "retries a failed bootstrap without reloading the successful sibling", %{
    options: options,
    state: state
  } do
    [_, label] = Setup.labels()
    Agent.update(state, &%{&1 | failures: %{{"bootstrap", label} => {"load failed", 1}}})
    assert {:error, "load failed"} = Setup.install(options)
    take_calls(state)
    before = plist_metadata()

    Agent.update(state, &%{&1 | failures: %{}})
    assert :ok = Setup.install(options)
    assert take_calls(state) == [{"bootstrap", label}]
    assert plist_metadata(touch?: false) == before
  end

  test "removes the obsolete thermal agent while preserving current jobs", %{
    options: options,
    state: state
  } do
    assert :ok = Setup.install(options)
    take_calls(state)
    [label] = Setup.obsolete_agent_labels()
    File.write!(plist_path(label), "obsolete configuration")
    Agent.update(state, &%{&1 | loaded: MapSet.put(&1.loaded, label)})
    before = plist_metadata()

    assert :ok = Setup.install(options)
    assert take_calls(state) == [{"bootout", label}]
    refute File.exists?(plist_path(label))
    assert plist_metadata(touch?: false) == before
  end

  defp launchctl(["list", label], state) do
    result = if MapSet.member?(state.loaded, label), do: {"loaded", 0}, else: {"not loaded", 1}
    {result, state}
  end

  defp launchctl([command | args], state) when command in ["bootstrap", "bootout"] do
    label = args |> List.last() |> Path.basename(".plist")
    call = {command, label}
    state = %{state | calls: state.calls ++ [call]}

    case Map.fetch(state.failures, call) do
      {:ok, result} ->
        {result, state}

      :error ->
        loaded =
          if command == "bootstrap",
            do: MapSet.put(state.loaded, label),
            else: MapSet.delete(state.loaded, label)

        {{"", 0}, %{state | loaded: loaded}}
    end
  end

  defp take_calls(state), do: Agent.get_and_update(state, &{&1.calls, %{&1 | calls: []}})
  defp plist_path(label), do: Path.join(Paths.launch_agents_dir(), "#{label}.plist")

  defp plist_metadata(options \\ []) do
    for label <- Setup.labels() do
      path = plist_path(label)
      if Keyword.get(options, :touch?, true), do: File.touch!(path, 1_700_000_000)
      stat = File.stat!(path)
      {stat.inode, stat.mtime}
    end
  end
end
