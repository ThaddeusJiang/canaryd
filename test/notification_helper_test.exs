defmodule Canaryd.NotificationHelperTest do
  use ExUnit.Case, async: true

  alias Canaryd.NotificationHelper

  test "does not activate or take focus" do
    source = NotificationHelper.source()

    assert source =~ "setActivationPolicy(.accessory)"
    assert source =~ "application.run()"
    refute source =~ ".activate("
    refute source =~ "activateIgnoringOtherApps"
  end

  test "registers close and restart notification actions" do
    source = NotificationHelper.source()

    assert source =~ ~s(title: "Close")
    assert source =~ ~s(title: "Restart")
    assert source =~ "options: [.customDismissAction]"
  end

  test "keeps an informational warning until the user dismisses it" do
    source = NotificationHelper.source()

    assert source =~ ~s|finish("scheduled", removeDelivered: false)|
    assert source =~ ~s|finish("ignore")|
  end

  test "uses the Canaryd name and logo" do
    assert NotificationHelper.bundle_spec() == %{
             app_name: "Canaryd.app",
             display_name: "Canaryd",
             icon_name: "Canaryd.icns"
           }
  end
end
