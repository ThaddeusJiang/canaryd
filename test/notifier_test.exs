defmodule Canaryd.NotifierTest do
  use ExUnit.Case, async: true

  alias Canaryd.Notifier

  test "parses interactive app actions" do
    assert Notifier.parse_app_action("restart\n") == {:ok, :restart}
    assert Notifier.parse_app_action("close\n") == {:ok, :close}
    assert Notifier.parse_app_action("ignore\n") == {:ok, :ignore}
    assert Notifier.parse_app_action("unknown\n") == {:error, :invalid_action}
  end
end
