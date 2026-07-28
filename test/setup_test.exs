defmodule Canaryd.SetupTest do
  use ExUnit.Case, async: true

  alias Canaryd.Setup

  test "keeps full checks at five minutes and thermal checks at one minute" do
    assert [
             %{label: "com.thaddeusjiang.canaryd", command: "check", interval_sec: 300},
             %{
               label: "com.thaddeusjiang.canaryd.thermal",
               command: "thermal-check",
               interval_sec: 60
             }
           ] = Setup.agent_specs("/Applications/canaryd")
  end
end
