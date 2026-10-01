defmodule Canaryd.SetupTest do
  use ExUnit.Case, async: true

  alias Canaryd.Setup

  test "uses the Burrito wrapper path for launchd" do
    assert Setup.executable_path("/Users/test/bin/canaryd", ~c"") ==
             "/Users/test/bin/canaryd"
  end

  test "keeps the escript path when no Burrito wrapper exists" do
    assert Setup.executable_path(nil, ~c"/Users/test/.mix/escripts/canaryd") ==
             "/Users/test/.mix/escripts/canaryd"
  end

  test "runs the full health check every five minutes without daily cleanup" do
    assert Setup.labels() == ["com.thaddeusjiang.canaryd"]

    assert [
             %{
               label: "com.thaddeusjiang.canaryd",
               command: "check",
               calendar: calendar,
               run_at_load: true
             }
           ] = Setup.agent_specs("/Applications/canaryd")

    assert calendar == Enum.map(0..11, &%{minute: &1 * 5})
  end

  test "uses calendar slots so missed checks coalesce at wake" do
    [agent] = Setup.agent_specs("/Applications/canaryd")

    assert Setup.agent_plist(agent) =~
             ~r/<key>StartCalendarInterval<\/key>\s+<array>/

    assert Setup.agent_plist(agent) =~ "<key>RunAtLoad</key>"
    refute Setup.agent_plist(agent) =~ "<key>StartInterval</key>"
    assert length(Regex.scan(~r/<key>Minute<\/key>/, Setup.agent_plist(agent))) == 12
  end

  test "marks the old daily cleanup and dedicated thermal agents as obsolete" do
    assert Setup.obsolete_agent_labels() == [
             "com.thaddeusjiang.canaryd.thermal",
             "com.thaddeusjiang.canaryd.build-cleanup"
           ]
  end

  test "launchd can resolve the system load sampler" do
    for agent <- Setup.agent_specs("/Applications/canaryd") do
      [_, path] =
        Regex.run(~r/<key>PATH<\/key>\s*<string>([^<]+)<\/string>/, Setup.agent_plist(agent))

      assert {"/usr/sbin/sysctl\n", 0} =
               System.cmd("/bin/sh", ["-c", "command -v sysctl"], env: [{"PATH", path}])
    end
  end
end
