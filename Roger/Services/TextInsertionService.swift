import AppKit
import ApplicationServices
import os

private let logger = Logger(subsystem: "com.jordiboehme.roger", category: "TextInsertion")

final class TextInsertionService {

    func insertText(_ text: String, restoreClipboard: Bool) throws {
        // Try Accessibility API first
        if tryAccessibilityInsertion(text) {
            logger.info("Text inserted via Accessibility API")
            return
        }

        // Fall back to clipboard + Cmd+V
        logger.info("Accessibility insertion failed, falling back to clipboard paste")
        try clipboardPaste(text, restoreClipboard: restoreClipboard)
    }

    // MARK: - Accessibility API

    private func tryAccessibilityInsertion(_ text: String) -> Bool {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedElement: AnyObject?

        let result = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElement
        )

        guard result == .success, let element = focusedElement else {
            logger.debug("Could not get focused element")
            return false
        }

        let axElement = element as! AXUIElement

        // Check role — only text fields and text areas support selected text insertion
        var roleValue: AnyObject?
        AXUIElementCopyAttributeValue(axElement, kAXRoleAttribute as CFString, &roleValue)
        let role = roleValue as? String

        guard role == kAXTextFieldRole || role == kAXTextAreaRole else {
            logger.debug("Focused element role '\(role ?? "nil")' doesn't support text insertion")
            return false
        }

        // Read current value to verify insertion worked
        var currentValue: AnyObject?
        AXUIElementCopyAttributeValue(axElement, kAXValueAttribute as CFString, &currentValue)
        let valueBefore = currentValue as? String

        // Set selected text (inserts at cursor position)
        let setResult = AXUIElementSetAttributeValue(
            axElement,
            kAXSelectedTextAttribute as CFString,
            text as CFTypeRef
        )

        guard setResult == .success else {
            logger.debug("AX set selected text failed: \(setResult.rawValue)")
            return false
        }

        // Verify the value actually changed
        var newValue: AnyObject?
        AXUIElementCopyAttributeValue(axElement, kAXValueAttribute as CFString, &newValue)
        let valueAfter = newValue as? String

        if valueBefore == valueAfter {
            logger.debug("AX insertion appeared to succeed but value unchanged — silent failure")
            return false
        }

        return true
    }

    // MARK: - Clipboard + Paste Fallback

    private func clipboardPaste(_ text: String, restoreClipboard: Bool) throws {
        let pasteboard = NSPasteboard.general

        // Save current clipboard if requested
        var savedItems: [NSPasteboardItem]?
        if restoreClipboard {
            savedItems = pasteboard.pasteboardItems?.compactMap { item -> NSPasteboardItem? in
                let newItem = NSPasteboardItem()
                for type in item.types {
                    if let data = item.data(forType: type) {
                        newItem.setData(data, forType: type)
                    }
                }
                return newItem
            }
        }

        // Set our text
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Simulate Cmd+V
        simulatePaste()

        // Restore clipboard after giving the target app time to process the paste
        if restoreClipboard, let savedItems {
            Thread.sleep(forTimeInterval: 0.5)
            pasteboard.clearContents()
            pasteboard.writeObjects(savedItems)
        }
    }

    private func simulatePaste() {
        let source = CGEventSource(stateID: .hidSystemState)

        // Key code 9 = V
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)

        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand

        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }
}
