defmodule Canaryd.SetupTest do
  use ExUnit.Case, async: true

  alias Canaryd.Setup

  test "keeps full checks at five minutes and thermal checks at one minute" do
    assert [
             %{label: "com.thaddeusjiang.canaryd", command: "check", interval: 300},
             %{
               label: "com.thaddeusjiang.canaryd.thermal",
               command: "thermal-check",
               interval: 60
             }
           ] = Setup.agent_specs("/Applications/canaryd")
  end
end
