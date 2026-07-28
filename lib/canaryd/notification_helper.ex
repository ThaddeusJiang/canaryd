defmodule Canaryd.NotificationHelper do
  @moduledoc false

  alias Canaryd.Store

  @app_name "Canaryd.app"
  @display_name "Canaryd"
  @icon_name "Canaryd.icns"
  @legacy_app_name "Canaryd Notifications.app"
  @executable_name "canaryd-notification"
  @source_path Path.expand("../../priv/canaryd_notification.swift", __DIR__)
  @icon_path Path.expand("../../priv/Canaryd.icns", __DIR__)
  @external_resource @source_path
  @external_resource @icon_path
  @source File.read!(@source_path)
  @icon File.read!(@icon_path)

  @doc false
  def executable_path do
    Path.join([app_path(), "Contents", "MacOS", @executable_name])
  end

  @doc false
  def source, do: @source

  @doc false
  def bundle_spec do
    %{app_name: @app_name, display_name: @display_name, icon_name: @icon_name}
  end

  @doc false
  def ensure_installed do
    if current_install?() and File.exists?(executable_path()) do
      :ok
    else
      install()
    end
  end

  @doc false
  def remove do
    File.rm_rf(app_path())
    File.rm_rf(legacy_app_path())
    :ok
  end

  defp install do
    File.mkdir_p!(Store.dir())
    build_dir = build_dir()
    build_app_path = Path.join(build_dir, @app_name)
    contents_path = Path.join(build_app_path, "Contents")
    executable_dir = Path.join(contents_path, "MacOS")
    resources_dir = Path.join(contents_path, "Resources")
    source_path = Path.join(resources_dir, "canaryd_notification.swift")
    executable_path = Path.join(executable_dir, @executable_name)

    try do
      File.mkdir_p!(executable_dir)
      File.mkdir_p!(resources_dir)
      File.write!(source_path, @source)
      File.write!(Path.join(resources_dir, @icon_name), @icon)
      File.write!(Path.join(contents_path, "Info.plist"), info_plist())

      with {_, 0} <-
             System.cmd("/usr/bin/swiftc", [source_path, "-o", executable_path],
               stderr_to_stdout: true
             ),
           {_, 0} <-
             System.cmd(
               "/usr/bin/codesign",
               ["--force", "--sign", "-", build_app_path],
               stderr_to_stdout: true
             ) do
        File.rm_rf(app_path())
        File.rename!(build_app_path, app_path())
        File.rm_rf(legacy_app_path())
        :ok
      else
        {output, _status} -> {:error, {:notification_helper_install_failed, String.trim(output)}}
      end
    rescue
      error -> {:error, {:notification_helper_install_failed, Exception.message(error)}}
    after
      File.rm_rf(build_dir)
    end
  end

  defp current_install? do
    current_source_path =
      Path.join([app_path(), "Contents", "Resources", "canaryd_notification.swift"])

    current_plist_path = Path.join([app_path(), "Contents", "Info.plist"])
    current_icon_path = Path.join([app_path(), "Contents", "Resources", @icon_name])

    File.read(current_source_path) == {:ok, @source} and
      File.read(current_plist_path) == {:ok, info_plist()} and
      File.read(current_icon_path) == {:ok, @icon}
  end

  defp app_path, do: Path.join(Store.dir(), @app_name)
  defp legacy_app_path, do: Path.join(Store.dir(), @legacy_app_name)

  defp build_dir do
    Path.join(Store.dir(), ".notification-build-#{System.unique_integer([:positive])}")
  end

  defp info_plist do
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
      <key>CFBundleDevelopmentRegion</key>
      <string>en</string>
      <key>CFBundleExecutable</key>
      <string>#{@executable_name}</string>
      <key>CFBundleDisplayName</key>
      <string>#{@display_name}</string>
      <key>CFBundleIdentifier</key>
      <string>com.thaddeusjiang.canaryd.notifications</string>
      <key>CFBundleIconFile</key>
      <string>#{@icon_name}</string>
      <key>CFBundleInfoDictionaryVersion</key>
      <string>6.0</string>
      <key>CFBundleName</key>
      <string>#{@display_name}</string>
      <key>CFBundlePackageType</key>
      <string>APPL</string>
      <key>CFBundleShortVersionString</key>
      <string>1.0.0</string>
      <key>CFBundleVersion</key>
      <string>1</string>
      <key>LSMinimumSystemVersion</key>
      <string>11.0</string>
      <key>LSUIElement</key>
      <true/>
    </dict>
    </plist>
    """
  end
end
