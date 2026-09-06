import AppKit
import ApplicationServices

struct DictationInsertionTarget {
    fileprivate let element: AXUIElement?

    init(element: AXUIElement?) {
        self.element = element
    }
}

@MainActor
final class DictationInsertionService {
    func captureTarget() -> DictationInsertionTarget {
        let system = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            system,
            kAXFocusedUIElementAttribute as CFString,
            &value
        )
        guard result == .success, let value else {
            return DictationInsertionTarget(element: nil)
        }
        return DictationInsertionTarget(element: (value as! AXUIElement))
    }

    func insert(_ text: String, into target: DictationInsertionTarget) throws {
        guard !text.isEmpty else { throw RealtimeDictationError.noText }
        if let element = target.element {
            guard !isSecure(element) else {
                throw RealtimeDictationError.secureTextField
            }
            if AXUIElementSetAttributeValue(
                element,
                kAXSelectedTextAttribute as CFString,
                text as CFTypeRef
            ) == .success {
                return
            }
        }
        try paste(text)
    }

    private func isSecure(_ element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSubroleAttribute as CFString,
            &value
        ) == .success,
        let subrole = value as? String else {
            return false
        }
        return subrole == (kAXSecureTextFieldSubrole as String)
    }

    private func paste(_ text: String) throws {
        let pasteboard = NSPasteboard.general
        let backup = pasteboard.pasteboardItems?.map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in
                item.data(forType: type).map { (type, $0) }
            })
        } ?? []

        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            throw RealtimeDictationError.serverFailed("Could not write to the pasteboard.")
        }

        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(
                keyboardEventSource: source,
                virtualKey: 9,
                keyDown: true
              ),
              let up = CGEvent(
                keyboardEventSource: source,
                virtualKey: 9,
                keyDown: false
              ) else {
            throw RealtimeDictationError.serverFailed("Could not synthesize the paste shortcut.")
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            pasteboard.clearContents()
            let items = backup.map { values -> NSPasteboardItem in
                let item = NSPasteboardItem()
                for (type, data) in values {
                    item.setData(data, forType: type)
                }
                return item
            }
            if !items.isEmpty {
                pasteboard.writeObjects(items)
            }
        }
    }
}
