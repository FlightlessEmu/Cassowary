// Run with Scripts/cassowary/test-keyboard-input.sh.
import Foundation
import GameController

// Record what the production manager sends without starting an emulator.
@MainActor
final class GameSession {
    var events: [String] = []

    func handleKeyEvent(keyCode: Int, isDown: Bool) {
        events.append("\(keyCode):\(isDown)")
    }
}

func onMain(_ work: @escaping @MainActor () -> Void) {
    if Thread.isMainThread {
        MainActor.assumeIsolated { work() }
    } else {
        Task { @MainActor in work() }
    }
}

@main
struct KeyboardControlManagerCheck {
    @MainActor
    static func main() {
        let session = GameSession()
        let input = KeyboardControlManager(session: session)
        let a = GCKeyCode.keyA.rawValue
        let command = GCKeyCode.leftGUI.rawValue
        let s = GCKeyCode.keyS.rawValue

        // UIKit and GameController may report the same transition.
        input.handle(keyCode: a, isDown: true)
        input.handle(keyCode: a, isDown: true)
        input.handle(keyCode: a, isDown: false)
        input.handle(keyCode: a, isDown: false)
        assert(session.events == ["\(a):true", "\(a):false"])
        session.events.removeAll()

        // Switch away while A and Command are held. Their releases happen
        // elsewhere, and an app shortcut must never become a game press.
        input.handle(keyCode: a, isDown: true)
        input.handle(keyCode: command, isDown: true)
        input.handle(keyCode: s, isDown: true)
        input.setActive(false)
        assert(Set(session.events.suffix(2)) == ["\(a):false", "\(command):false"])
        assert(!session.events.contains("\(s):true"))
        assert(!session.events.contains("\(s):false"))
        session.events.removeAll()

        input.handle(keyCode: a, isDown: true)
        input.handle(keyCode: command, isDown: true)
        assert(session.events.isEmpty, "An inactive game must ignore keyboard input")

        // Returning must accept A without needing another Command release.
        input.setActive(true)
        input.handle(keyCode: a, isDown: true)
        input.stop()
        assert(session.events == ["\(a):true", "\(a):false"],
               "Lost modifier releases must not block keys after returning")
        print("PASS: keyboard duplicates, shortcuts, focus changes, and held-key cleanup")
    }
}
