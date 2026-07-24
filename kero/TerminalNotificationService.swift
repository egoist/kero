//
//  TerminalNotificationService.swift
//  kero
//

import Foundation
import UserNotifications

/// Delivers terminal notification requests through macOS Notification Center.
/// Authorization is intentionally deferred until a terminal first asks to
/// notify, rather than prompting at app launch.
final class TerminalNotificationService: NSObject, UNUserNotificationCenterDelegate {
    static let shared = TerminalNotificationService()

    private let center = UNUserNotificationCenter.current()
    private var isRequestingAuthorization = false
    private var pendingMessage: String?

    func configure() {
        center.delegate = self
    }

    func post(message: String) {
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            self?.checkAuthorization(for: message)
        }
    }

    private func checkAuthorization(for message: String) {
        center.getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async {
                self?.handle(settings.authorizationStatus, message: message)
            }
        }
    }

    private func handle(_ status: UNAuthorizationStatus, message: String) {
        switch status {
        case .authorized, .provisional:
            deliver(message)
        case .notDetermined:
            // A terminal can emit OSC 9 repeatedly while the permission sheet
            // is open. Keep only the latest request so an untrusted process
            // cannot grow an unbounded queue or release a banner storm.
            pendingMessage = message
            guard !isRequestingAuthorization else { return }

            isRequestingAuthorization = true
            center.requestAuthorization(options: [.alert]) { [weak self] granted, error in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.isRequestingAuthorization = false

                    let message = self.pendingMessage
                    self.pendingMessage = nil

                    if let error {
                        NSLog("Kero: notification authorization failed: %@", String(describing: error))
                    }
                    if granted, let message {
                        self.deliver(message)
                    }
                }
            }
        case .denied:
            break
        @unknown default:
            break
        }
    }

    private func deliver(_ message: String) {
        let content = UNMutableNotificationContent()
        content.title = "Kero"
        content.body = message

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        center.add(request) { error in
            if let error {
                NSLog("Kero: terminal notification failed: %@", String(describing: error))
            }
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner])
    }
}
