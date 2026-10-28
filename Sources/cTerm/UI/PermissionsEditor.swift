import AppKit

/// The accessory of the "权限" sheet: read/write/execute boxes for owner,
/// group and others, kept in step with an octal field like 755.
final class PermissionsEditor: NSView, NSTextFieldDelegate {
    private(set) var mode: UInt32
    private var boxes: [NSButton] = []
    private let octalField = NSTextField()
    private let recursiveBox = NSButton(checkboxWithTitle: "应用到其中所有文件和文件夹", target: nil, action: nil)
    private let offerRecursive: Bool

    var isRecursive: Bool { offerRecursive && recursiveBox.state == .on }

    init(mode: UInt32, offerRecursive: Bool) {
        self.mode = mode
        self.offerRecursive = offerRecursive
        super.init(frame: NSRect(x: 0, y: 0, width: 280, height: offerRecursive ? 168 : 140))

        func header(_ text: String) -> NSTextField {
            let label = NSTextField(labelWithString: text)
            label.font = .systemFont(ofSize: 12, weight: .medium)
            label.textColor = .secondaryLabelColor
            label.alignment = .center
            return label
        }
        var rows: [[NSView]] = [[NSView(), header("读取"), header("写入"), header("执行")]]
        for (index, who) in ["所有者", "群组", "其他人"].enumerated() {
            var row: [NSView] = [NSTextField(labelWithString: who)]
            for bit in 0..<3 {
                let box = NSButton(checkboxWithTitle: "", target: self, action: #selector(boxToggled(_:)))
                // Owner read is the highest bit: 0o400 >> (3 * row + bit).
                box.tag = Int(0o400 >> UInt32(3 * index + bit))
                boxes.append(box)
                row.append(box)
            }
            rows.append(row)
        }
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 8
        grid.columnSpacing = 18
        grid.yPlacement = .center
        for column in 1..<4 { grid.column(at: column).xPlacement = .center }
        grid.translatesAutoresizingMaskIntoConstraints = false

        let octalLabel = NSTextField(labelWithString: "数字表示")
        octalLabel.translatesAutoresizingMaskIntoConstraints = false
        octalField.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        octalField.delegate = self
        octalField.alignment = .center
        octalField.translatesAutoresizingMaskIntoConstraints = false
        recursiveBox.translatesAutoresizingMaskIntoConstraints = false
        recursiveBox.isHidden = !offerRecursive

        [grid, octalLabel, octalField, recursiveBox].forEach(addSubview)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            grid.leadingAnchor.constraint(equalTo: leadingAnchor),
            octalLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            octalLabel.centerYAnchor.constraint(equalTo: octalField.centerYAnchor),
            octalField.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 14),
            octalField.leadingAnchor.constraint(equalTo: octalLabel.trailingAnchor, constant: 10),
            octalField.widthAnchor.constraint(equalToConstant: 64),
            recursiveBox.topAnchor.constraint(equalTo: octalField.bottomAnchor, constant: 12),
            recursiveBox.leadingAnchor.constraint(equalTo: leadingAnchor)
        ])
        refresh(updateField: true)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func boxToggled(_ sender: NSButton) {
        let bit = UInt32(sender.tag)
        mode = sender.state == .on ? mode | bit : mode & ~bit
        refresh(updateField: true)
    }

    func controlTextDidChange(_ notification: Notification) {
        let text = octalField.stringValue.trimmingCharacters(in: .whitespaces)
        guard text.count == 3, let value = UInt32(text, radix: 8) else { return }
        mode = value
        refresh(updateField: false)
    }

    private func refresh(updateField: Bool) {
        for box in boxes { box.state = mode & UInt32(box.tag) != 0 ? .on : .off }
        if updateField {
            let text = String(mode & 0o777, radix: 8)
            octalField.stringValue = String(repeating: "0", count: max(0, 3 - text.count)) + text
        }
    }
}
