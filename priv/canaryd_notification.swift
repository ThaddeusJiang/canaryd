import AppKit
import CoreServices
import Foundation
import UserNotifications

private let closeAction = "close"
private let restartAction = "restart"
private let categoryIdentifier = "canaryd.process-action"

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
    exit(1)
}

final class ApplicationDelegate: NSObject, NSApplicationDelegate,
    UNUserNotificationCenterDelegate
{
    private let mode: String
    private let title: String
    private let body: String
    private let timeout: TimeInterval
    private let center = UNUserNotificationCenter.current()
    private var requestIdentifier: String?
    private var authorizationTimer: Timer?
    private var notificationTimer: Timer?

    init(mode: String, title: String, body: String, timeout: TimeInterval) {
        self.mode = mode
        self.title = title
        self.body = body
        self.timeout = timeout
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = LSRegisterURL(
            Bundle.main.bundleURL as CFURL,
            true
        )

        center.delegate = self
        authorizationTimer = Timer.scheduledTimer(
            withTimeInterval: 30,
            repeats: false
        ) { _ in
            fail("notification authorization timed out")
        }

        center.requestAuthorization(options: [.alert, .sound]) {
            [weak self] granted, error in
            DispatchQueue.main.async {
                self?.completeAuthorization(granted: granted, error: error)
            }
        }
    }

    private func completeAuthorization(granted: Bool, error: Error?) {
        authorizationTimer?.invalidate()

        guard granted else {
            fail(error?.localizedDescription ?? "notifications are not authorized")
        }

        if mode == "action" {
            registerActionCategory()
        }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        if mode == "action" {
            content.categoryIdentifier = categoryIdentifier
        }

        let identifier = UUID().uuidString
        requestIdentifier = identifier
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil
        )

        center.add(request) { [weak self] error in
            DispatchQueue.main.async {
                self?.completeDelivery(error: error)
            }
        }
    }

    private func registerActionCategory() {
        let close = UNNotificationAction(
            identifier: closeAction,
            title: "Close",
            options: [.destructive]
        )
        let restart = UNNotificationAction(
            identifier: restartAction,
            title: "Restart",
            options: [.destructive]
        )
        let category = UNNotificationCategory(
            identifier: categoryIdentifier,
            actions: [close, restart],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )
        center.setNotificationCategories([category])
    }

    private func completeDelivery(error: Error?) {
        if let error {
            fail(error.localizedDescription)
        }

        if mode == "notify" {
            finish("scheduled", removeDelivered: false)
            return
        }

        notificationTimer = Timer.scheduledTimer(
            withTimeInterval: timeout,
            repeats: false
        ) { [weak self] _ in
            self?.finish("ignore")
        }
    }

    private func finish(_ result: String, removeDelivered: Bool = true) {
        authorizationTimer?.invalidate()
        notificationTimer?.invalidate()

        if removeDelivered, let requestIdentifier {
            center.removeDeliveredNotifications(withIdentifiers: [requestIdentifier])
        }

        print(result)
        NSApplication.shared.terminate(nil)
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler:
            @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let result: String

        switch response.actionIdentifier {
        case closeAction:
            result = closeAction
        case restartAction:
            result = restartAction
        default:
            result = "ignore"
        }

        completionHandler()
        finish(result)
    }
}

let arguments = CommandLine.arguments

guard arguments.count == 5 else {
    fail("usage: canaryd-notification MODE TITLE BODY TIMEOUT")
}

let mode = arguments[1]
let title = arguments[2]
let body = arguments[3]

guard mode == "notify" || mode == "action" else {
    fail("invalid notification mode")
}

guard let timeout = TimeInterval(arguments[4]), timeout > 0 else {
    fail("invalid notification timeout")
}

let application = NSApplication.shared
let applicationDelegate = ApplicationDelegate(
    mode: mode,
    title: title,
    body: body,
    timeout: timeout
)
application.setActivationPolicy(.accessory)
application.delegate = applicationDelegate
application.run()
