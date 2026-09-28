defmodule Canaryd.CheckerPolicyConfigTest do
  use ExUnit.Case, async: false

  alias Canaryd.{Checker, Setup}

  test "invalid policy prevents a check and launchd installation before any action" do
    previous_home = System.get_env("HOME")

    home =
      Path.join(System.tmp_dir!(), "canaryd-invalid-policy-#{System.unique_integer([:positive])}")

    on_exit(fn ->
      if previous_home, do: System.put_env("HOME", previous_home), else: System.delete_env("HOME")
      File.rm_rf!(home)
    end)

    path =
      Path.join([home, "Library", "Application Support", "canaryd", "thresholds", "memory-rss"])

    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "invalid")
    System.put_env("HOME", home)

    assert Checker.run() == {:error, {"memory-rss", :invalid_value}}
    assert Checker.run_thermal() == {:error, {"memory-rss", :invalid_value}}

    assert Setup.install(
             ensure_notification_helper: fn -> flunk("must not install helper") end,
             runner: fn _, _, _ -> flunk("must not touch launchd") end
           ) == {:error, {"memory-rss", :invalid_value}}

    refute File.exists?(
             Path.join([home, "Library", "Application Support", "canaryd", "state.dets"])
           )
  end
end
