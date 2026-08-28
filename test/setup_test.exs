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

  test "runs the full health check every five minutes and build cleanup daily" do
    assert Setup.labels() == [
             "com.thaddeusjiang.canaryd",
             "com.thaddeusjiang.canaryd.build-cleanup"
           ]

    assert [
             %{
               label: "com.thaddeusjiang.canaryd",
               command: "check",
               interval: 300_000,
               run_at_load: true
             },
             %{
               label: "com.thaddeusjiang.canaryd.build-cleanup",
               command: "clean",
               calendar: %{hour: 4, minute: 0},
               run_at_load: false
             }
           ] = Setup.agent_specs("/Applications/canaryd")
  end

  test "converts the interval to launchd seconds at the plist boundary" do
    [agent, _cleanup_agent] = Setup.agent_specs("/Applications/canaryd")

    assert Setup.agent_plist(agent) =~
             ~r/<key>StartInterval<\/key>\s+<integer>300<\/integer>/

    assert Setup.agent_plist(agent) =~ "<key>RunAtLoad</key>"
  end

  test "renders cleanup at 04:00 without running it during installation" do
    [_check_agent, cleanup_agent] = Setup.agent_specs("/Applications/canaryd")
    plist = Setup.agent_plist(cleanup_agent)

    assert plist =~ ~r/<key>StartCalendarInterval<\/key>\s+<dict>/
    assert plist =~ ~r/<key>Hour<\/key>\s+<integer>4<\/integer>/
    assert plist =~ ~r/<key>Minute<\/key>\s+<integer>0<\/integer>/
    refute plist =~ "<key>RunAtLoad</key>"
  end

  test "marks the dedicated thermal agent as obsolete" do
    assert Setup.obsolete_agent_labels() == ["com.thaddeusjiang.canaryd.thermal"]
  end
end
