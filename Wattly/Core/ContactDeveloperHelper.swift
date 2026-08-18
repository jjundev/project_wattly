import Foundation
import AppKit

enum ContactDeveloperHelper: Sendable {
    static let email = "jjundev@gmail.com"
    static let defaultSubject = "[Wattly] 문의 및 피드백"

    static func generateDiagnosticBody(
        version: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0",
        build: String = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1",
        osVersion: String = ProcessInfo.processInfo.operatingSystemVersionString,
        hardwareModel: String = currentHardwareModel()
    ) -> String {
        """
        
        
        --------------------
        • Wattly Version: v\(version) (\(build))
        • macOS: \(osVersion)
        • Hardware Model: \(hardwareModel.isEmpty ? "Unknown" : hardwareModel)
        --------------------
        """
    }

    static func buildGmailWebComposeURL(
        email: String = email,
        subject: String = defaultSubject,
        body: String? = nil
    ) -> URL? {
        var components = URLComponents(string: "https://mail.google.com/mail/")
        var queryItems = [
            URLQueryItem(name: "view", value: "cm"),
            URLQueryItem(name: "fs", value: "1"),
            URLQueryItem(name: "to", value: email)
        ]
        if !subject.isEmpty {
            queryItems.append(URLQueryItem(name: "su", value: subject))
        }
        let mailBody = body ?? generateDiagnosticBody()
        if !mailBody.isEmpty {
            queryItems.append(URLQueryItem(name: "body", value: mailBody))
        }
        components?.queryItems = queryItems
        return components?.url
    }

    @discardableResult
    @MainActor
    static func openContactEmailInBrowser(
        email: String = email,
        subject: String = defaultSubject,
        body: String? = nil,
        workspace: NSWorkspace = .shared,
        pasteboard: NSPasteboard = .general
    ) -> Bool {
        guard let url = buildGmailWebComposeURL(email: email, subject: subject, body: body) else {
            copyEmailToClipboard(email: email, pasteboard: pasteboard)
            return false
        }

        let opened = workspace.open(url)
        if !opened {
            copyEmailToClipboard(email: email, pasteboard: pasteboard)
        }
        return opened
    }

    static func copyEmailToClipboard(
        email: String = email,
        pasteboard: NSPasteboard = .general
    ) {
        pasteboard.clearContents()
        pasteboard.setString(email, forType: .string)
    }
}
