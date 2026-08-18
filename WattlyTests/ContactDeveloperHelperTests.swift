import Testing
import Foundation
import AppKit
@testable import Wattly

@Suite struct ContactDeveloperHelperTests {
    @Test func emailAddressMatchesRequirement() {
        #expect(ContactDeveloperHelper.email == "jjundev@gmail.com")
    }

    @Test func diagnosticBodyContainsVersionAndSystemInfo() {
        let body = ContactDeveloperHelper.generateDiagnosticBody(
            version: "1.0.3",
            build: "4",
            osVersion: "macOS 14.5",
            hardwareModel: "Mac14,2"
        )
        #expect(body.contains("Wattly Version: v1.0.3 (4)"))
        #expect(body.contains("macOS: macOS 14.5"))
        #expect(body.contains("Hardware Model: Mac14,2"))
    }

    @Test func buildGmailWebComposeURLConstructsValidURL() {
        let url = ContactDeveloperHelper.buildGmailWebComposeURL(
            email: "jjundev@gmail.com",
            subject: "[Wattly] Feedback",
            body: "Test Body"
        )
        #expect(url != nil)
        #expect(url?.scheme == "https")
        #expect(url?.host == "mail.google.com")
        let absoluteString = url?.absoluteString ?? ""
        #expect(absoluteString.contains("view=cm"))
        #expect(absoluteString.contains("fs=1"))
        #expect(absoluteString.contains("to=jjundev@gmail.com"))
        #expect(absoluteString.contains("su=%5BWattly%5D%20Feedback"))
        #expect(absoluteString.contains("body=Test%20Body"))
    }

    @Test func copyEmailToClipboardSetsPasteboard() {
        let pb = NSPasteboard.withUniqueName()
        ContactDeveloperHelper.copyEmailToClipboard(email: "jjundev@gmail.com", pasteboard: pb)
        #expect(pb.string(forType: .string) == "jjundev@gmail.com")
    }
}
