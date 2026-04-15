import AppKit

// MARK: - Credential Entry Window (Apple ID + Password)

@MainActor
final class CredentialWindowController: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let appleIDField: NSTextField
    private let passwordField: NSSecureTextField
    private let signInButton: NSButton
    private let statusLabel: NSTextField
    private let tosCheckbox: NSButton

    private let onComplete: (String, String) -> Void
    private let onCancel: () -> Void

    init(
        savedAppleID: String? = nil,
        onComplete: @escaping (String, String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.onComplete = onComplete
        self.onCancel = onCancel

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Sign In to iCloud"
        window.isReleasedWhenClosed = false

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 260))

        // Title
        let titleLabel = NSTextField(labelWithString: "Apple ID")
        titleLabel.font = NSFont.systemFont(ofSize: 16, weight: .semibold)
        titleLabel.frame = NSRect(x: 30, y: 218, width: 300, height: 24)
        container.addSubview(titleLabel)

        let subtitleLabel = NSTextField(labelWithString: "Sign in with your Apple ID to access Find My devices.")
        subtitleLabel.font = NSFont.systemFont(ofSize: 12)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.frame = NSRect(x: 30, y: 195, width: 300, height: 20)
        container.addSubview(subtitleLabel)

        // Apple ID field
        appleIDField = NSTextField(frame: NSRect(x: 30, y: 160, width: 300, height: 24))
        appleIDField.placeholderString = "Apple ID (email)"
        appleIDField.stringValue = savedAppleID ?? ""
        container.addSubview(appleIDField)

        // Password field
        passwordField = NSSecureTextField(frame: NSRect(x: 30, y: 125, width: 300, height: 24))
        passwordField.placeholderString = "Password"
        container.addSubview(passwordField)

        // Privacy & ToS checkbox with clickable links
        tosCheckbox = NSButton(frame: NSRect(x: 28, y: 88, width: 20, height: 18))
        tosCheckbox.setButtonType(.switch)
        tosCheckbox.title = ""
        container.addSubview(tosCheckbox)

        let tosText = NSTextField(frame: NSRect(x: 48, y: 88, width: 285, height: 18))
        tosText.isEditable = false
        tosText.isBordered = false
        tosText.drawsBackground = false
        tosText.isSelectable = true
        tosText.allowsEditingTextAttributes = true

        let tosString = NSMutableAttributedString(string: "I accept the ")
        let privacyLink = NSMutableAttributedString(string: "Privacy Policy")
        privacyLink.addAttribute(.link, value: URL(string: "https://icamel.app/product/batterybar/privacy.html")!, range: NSRange(location: 0, length: privacyLink.length))
        let andText = NSAttributedString(string: " and ")
        let termsLink = NSMutableAttributedString(string: "Terms of Service")
        termsLink.addAttribute(.link, value: URL(string: "https://icamel.app/product/batterybar/terms.html")!, range: NSRange(location: 0, length: termsLink.length))

        tosString.append(privacyLink)
        tosString.append(andText)
        tosString.append(termsLink)
        tosString.addAttribute(.font, value: NSFont.systemFont(ofSize: 11), range: NSRange(location: 0, length: tosString.length))
        tosText.attributedStringValue = tosString
        container.addSubview(tosText)

        // Status label
        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.frame = NSRect(x: 30, y: 62, width: 300, height: 18)
        container.addSubview(statusLabel)

        // Sign In button (disabled until ToS checked)
        signInButton = NSButton(title: "Sign In", target: nil, action: nil)
        signInButton.bezelStyle = .rounded
        signInButton.keyEquivalent = "\r"
        signInButton.frame = NSRect(x: 230, y: 14, width: 100, height: 30)
        signInButton.isEnabled = false
        container.addSubview(signInButton)

        // Cancel button
        let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.frame = NSRect(x: 125, y: 14, width: 100, height: 30)
        container.addSubview(cancelButton)

        super.init()

        signInButton.target = self
        signInButton.action = #selector(signInClicked)
        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked)
        tosCheckbox.target = self
        tosCheckbox.action = #selector(tosChanged)
        window.delegate = self
        window.contentView = container
        window.center()
    }

    func showWindow() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        if appleIDField.stringValue.isEmpty {
            window.makeFirstResponder(appleIDField)
        } else {
            window.makeFirstResponder(passwordField)
        }
    }

    func close() {
        window.close()
    }

    func setStatus(_ text: String) {
        statusLabel.stringValue = text
    }

    @objc private func tosChanged() {
        signInButton.isEnabled = tosCheckbox.state == .on
    }

    @objc private func signInClicked() {
        let appleID = appleIDField.stringValue.trimmingCharacters(in: .whitespaces)
        let password = passwordField.stringValue
        guard !appleID.isEmpty, !password.isEmpty else {
            statusLabel.stringValue = "Please enter both Apple ID and password."
            return
        }
        guard tosCheckbox.state == .on else {
            statusLabel.stringValue = "Please accept the Privacy Policy and Terms of Service."
            return
        }
        statusLabel.stringValue = "Signing in..."
        signInButton.isEnabled = false
        onComplete(appleID, password)
    }

    @objc private func cancelClicked() {
        onCancel()
        close()
    }

    func windowWillClose(_ notification: Notification) {
        onCancel()
    }
}

// MARK: - 2FA Code Entry Window

@MainActor
final class TwoFAWindowController: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let codeField: NSTextField
    private var continuation: CheckedContinuation<String?, Never>?

    override init() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 150),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Two-Factor Authentication"
        window.isReleasedWhenClosed = false

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 150))

        let label = NSTextField(labelWithString: "Enter the code sent via SMS to your phone:")
        label.font = NSFont.systemFont(ofSize: 12)
        label.frame = NSRect(x: 20, y: 105, width: 260, height: 30)
        container.addSubview(label)

        codeField = NSTextField(frame: NSRect(x: 20, y: 72, width: 260, height: 28))
        codeField.placeholderString = "000000"
        codeField.font = NSFont.monospacedDigitSystemFont(ofSize: 18, weight: .medium)
        codeField.alignment = .center
        container.addSubview(codeField)

        let submitButton = NSButton(title: "Verify", target: nil, action: nil)
        submitButton.bezelStyle = .rounded
        submitButton.keyEquivalent = "\r"
        submitButton.frame = NSRect(x: 180, y: 14, width: 100, height: 30)
        container.addSubview(submitButton)

        let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.frame = NSRect(x: 75, y: 14, width: 100, height: 30)
        container.addSubview(cancelButton)

        super.init()

        submitButton.target = self
        submitButton.action = #selector(submitClicked)
        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked)
        window.delegate = self
        window.contentView = container
        window.center()
    }

    func getCode() async -> String? {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(codeField)

        return await withCheckedContinuation { c in
            self.continuation = c
        }
    }

    @objc private func submitClicked() {
        let code = codeField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !code.isEmpty else { return }
        let c = continuation
        continuation = nil
        window.close()
        c?.resume(returning: code)
    }

    @objc private func cancelClicked() {
        let c = continuation
        continuation = nil
        window.close()
        c?.resume(returning: nil)
    }

    func windowWillClose(_ notification: Notification) {
        continuation?.resume(returning: nil)
        continuation = nil
    }
}
