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

  test "registers the app bundle before it sends notifications" do
    source = NotificationHelper.source()

    assert source =~ "import CoreServices"
    assert source =~ "LSRegisterURL("
    assert source =~ "Bundle.main.bundleURL as CFURL"
  end

  test "keeps an informational warning until the user dismisses it" do
    source = NotificationHelper.source()

    assert source =~ ~s|finish("scheduled", removeDelivered: false)|
    assert source =~ ~s|finish("ignore")|
  end

  test "converts the millisecond command contract at the Swift timer boundary" do
    source = NotificationHelper.source()

    assert source =~ "duration / 1_000"
    assert source =~ "withTimeInterval: timerInterval(for: 30_000)"
    assert source =~ "withTimeInterval: timerInterval(for: timeout)"
  end

  test "uses the Canaryd name and logo" do
    assert NotificationHelper.bundle_spec() == %{
             app_name: "Canaryd.app",
             display_name: "Canaryd",
             icon_name: "Canaryd.icns"
           }
  end
end
