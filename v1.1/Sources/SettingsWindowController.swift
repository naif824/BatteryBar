import AppKit

/// Settings window with checkboxes to show/hide devices.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let scrollView: NSScrollView
    private let stackView: NSStackView
    private var checkboxes: [(NSButton, String)] = [] // (checkbox, deviceID)

    private let onSave: ([String]) -> Void // returns hidden device IDs
    private let onClose: () -> Void

    init(devices: [Device], hiddenIDs: [String], onSave: @escaping ([String]) -> Void, onClose: @escaping () -> Void) {
        self.onSave = onSave
        self.onClose = onClose

        stackView = NSStackView()
        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.spacing = 8
        stackView.translatesAutoresizingMaskIntoConstraints = false

        scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let clipView = NSClipView()
        clipView.documentView = stackView
        scrollView.contentView = clipView

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Visible Devices"
        window.isReleasedWhenClosed = false

        let container = NSView()
        container.addSubview(scrollView)

        super.init()
        window.delegate = self
        window.contentView = container

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
        ])

        // Build checkboxes
        let header = NSTextField(labelWithString: "Select devices to show in menu:")
        header.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        stackView.addArrangedSubview(header)

        for device in devices {
            let title = "\(device.kind.emoji)  \(device.name)"
            let cb = NSButton(checkboxWithTitle: title, target: self, action: #selector(checkboxChanged))
            cb.state = hiddenIDs.contains(device.id) ? .off : .on
            cb.font = NSFont.systemFont(ofSize: 13)
            stackView.addArrangedSubview(cb)
            checkboxes.append((cb, device.id))
        }

        // Size stack to fit
        NSLayoutConstraint.activate([
            stackView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor, constant: -20),
        ])

        window.center()
    }

    func showWindow() {
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func checkboxChanged() {
        let hidden = checkboxes.filter { $0.0.state == .off }.map { $0.1 }
        onSave(hidden)
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}
