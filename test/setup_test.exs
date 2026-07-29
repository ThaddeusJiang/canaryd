defmodule Canaryd.SetupTest do
  use ExUnit.Case, async: true

  alias Canaryd.Setup

  test "keeps full checks at five minutes and thermal checks at one minute" do
    assert [
             %{label: "com.thaddeusjiang.canaryd", command: "check", interval: 300_000},
             %{
               label: "com.thaddeusjiang.canaryd.thermal",
               command: "thermal-check",
               interval: 60_000
             }
           ] = Setup.agent_specs("/Applications/canaryd")
  end

  test "converts the interval to launchd seconds at the plist boundary" do
    [agent | _agents] = Setup.agent_specs("/Applications/canaryd")

    assert Setup.agent_plist(agent) =~
             ~r/<key>StartInterval<\/key>\s+<integer>300<\/integer>/
  end
end
