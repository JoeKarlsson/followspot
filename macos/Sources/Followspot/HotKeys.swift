import Carbon.HIToolbox

// System-wide ⌃⌥ shortcuts, so the prompter can be driven while a recording
// app has focus. RegisterEventHotKey needs no Accessibility permission. The
// page's own keys ignore ⌃/⌥ combos (keyAction in remote.js), so these
// never fire twice when Followspot is frontmost.
final class HotKeys {
  static let bindings: [(key: Int, label: String, action: String)] = [
    (kVK_Space, "⌃⌥Space", "listen"),
    (kVK_RightArrow, "⌃⌥→", "wordNext"),
    (kVK_LeftArrow, "⌃⌥←", "wordPrev"),
    (kVK_DownArrow, "⌃⌥↓", "paraNext"),
    (kVK_UpArrow, "⌃⌥↑", "paraPrev"),
    (kVK_ANSI_R, "⌃⌥R", "restart"),
  ]

  var onAction: ((String) -> Void)?
  private var refs: [EventHotKeyRef] = []
  private var handler: EventHandlerRef?

  func register() {
    guard refs.isEmpty else { return }
    var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(
      GetApplicationEventTarget(),
      { _, event, context in
        var id = EventHotKeyID()
        GetEventParameter(
          event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
          MemoryLayout<EventHotKeyID>.size, nil, &id)
        let me = Unmanaged<HotKeys>.fromOpaque(context!).takeUnretainedValue()
        if Int(id.id) < HotKeys.bindings.count { me.onAction?(HotKeys.bindings[Int(id.id)].action) }
        return noErr
      }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
    for (i, binding) in Self.bindings.enumerated() {
      var ref: EventHotKeyRef?
      let id = EventHotKeyID(signature: OSType(0x4653_5054), id: UInt32(i))  // 'FSPT'
      RegisterEventHotKey(
        UInt32(binding.key), UInt32(controlKey | optionKey), id, GetApplicationEventTarget(), 0, &ref)
      if let ref { refs.append(ref) }
    }
  }

  func unregister() {
    for ref in refs { UnregisterEventHotKey(ref) }
    refs = []
    if let handler { RemoveEventHandler(handler) }
    handler = nil
  }
}
