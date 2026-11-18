import Carbon

/// Selects the WeChat input method (WeType) so the injected Globe/FN tap
/// reaches WeType's own voice-input handler instead of the ABC layout.
enum InputMethodSwitcher {
    /// WeType registers as an input mode owned by com.tencent.inputmethod.wetype.
    private static let preferredInputSourceID = "com.tencent.inputmethod.wetype.pinyin"
    private static let vendorInputSourceIDPrefix = "com.tencent.inputmethod.wetype"

    /// Returns true when the current input source list contained a WeType
    /// source and the selection command was accepted. Selection is best
    /// effort: voice injection still proceeds when it fails (same as before
    /// this feature existed).
    @discardableResult
    static func selectWeChatInputSource() -> Bool {
        guard let sourceList = TISCreateInputSourceList(nil, false)?.takeRetainedValue()
            as? [TISInputSource] else {
            return false
        }

        let ids = sourceList.map { (source: TISInputSource) -> (TISInputSource, String?) in
            (source, inputSourceID(of: source))
        }

        if let exact = ids.first(where: { $0.1 == preferredInputSourceID }) {
            return TISSelectInputSource(exact.0) == noErr
        }
        if let vendorMatch = ids.first(where: {
            $0.1?.hasPrefix(vendorInputSourceIDPrefix) == true
        }) {
            return TISSelectInputSource(vendorMatch.0) == noErr
        }
        return false
    }

    private static func inputSourceID(of source: TISInputSource) -> String? {
        guard let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else {
            return nil
        }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }
}
