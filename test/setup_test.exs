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

  test "runs one full health check every five minutes" do
    assert [
             %{label: "com.thaddeusjiang.canaryd", command: "check", interval: 300_000}
           ] = Setup.agent_specs("/Applications/canaryd")
  end

  test "converts the interval to launchd seconds at the plist boundary" do
    [agent | _agents] = Setup.agent_specs("/Applications/canaryd")

    assert Setup.agent_plist(agent) =~
             ~r/<key>StartInterval<\/key>\s+<integer>300<\/integer>/
  end

  test "marks the dedicated thermal agent as obsolete" do
    assert Setup.obsolete_agent_labels() == ["com.thaddeusjiang.canaryd.thermal"]
  end
end
