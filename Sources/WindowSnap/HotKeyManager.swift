import Carbon

final class HotKeyManager {
    private var refs: [EventHotKeyRef] = []
    private var actions: [UInt32: WindowAction] = [:]
    var handler: ((WindowAction) -> Void)?

    init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return noErr }
            let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr, let action = manager.actions[id.id] else { return status }
            manager.handler?(action)
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
    }

    @discardableResult
    func register(_ values: [WindowAction: Shortcut]) -> [WindowAction] {
        refs.forEach { UnregisterEventHotKey($0) }
        refs.removeAll(); actions.removeAll()
        var failures: [WindowAction] = []
        for (index, action) in WindowAction.allCases.enumerated() {
            guard action.columnLayout == nil else { continue }
            guard let shortcut = values[action] else { continue }
            let id = EventHotKeyID(signature: OSType(0x57534E50), id: UInt32(index + 1)) // WSNP
            var ref: EventHotKeyRef?
            if RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, id, GetApplicationEventTarget(), 0, &ref) == noErr,
               let ref {
                refs.append(ref)
                actions[id.id] = action
            } else {
                failures.append(action)
            }
        }
        return failures
    }
}
