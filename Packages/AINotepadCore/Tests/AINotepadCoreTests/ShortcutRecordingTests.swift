import Foundation
import Testing
@testable import AINotepadCore

@Suite struct ShortcutRecordingTests {
    enum Action: Hashable, Sendable {
        case record
        case dictate
    }

    let idle: ShortcutRecordingState<Action> = ShortcutRecordingState(recording: nil)
    let recordingRecord: ShortcutRecordingState<Action> = ShortcutRecordingState(recording: .record)
    let commandShiftK: KeyBinding = KeyBinding(keyCode: 0x28, modifiers: CarbonModifier.command | CarbonModifier.shift)

    @Test func tappingStartsRecordingAndSuspendsHotKeys() {
        let result: ShortcutRecordingTransition<Action> = shortcutRecordingTransition(state: idle, event: .tapped(.record))
        #expect(result == ShortcutRecordingTransition(state: recordingRecord, effects: [.suspendHotKeys]))
    }

    @Test func tappingSameRecorderAgainStopsAndResumes() {
        let result: ShortcutRecordingTransition<Action> = shortcutRecordingTransition(state: recordingRecord, event: .tapped(.record))
        #expect(result == ShortcutRecordingTransition(state: idle, effects: [.resumeHotKeys]))
    }

    @Test func tappingAnotherRecorderMovesRecordingWithoutResuming() {
        let result: ShortcutRecordingTransition<Action> = shortcutRecordingTransition(state: recordingRecord, event: .tapped(.dictate))
        #expect(result == ShortcutRecordingTransition(state: ShortcutRecordingState(recording: .dictate), effects: []))
    }

    @Test func keyPressResumesBeforeAssigning() {
        let result: ShortcutRecordingTransition<Action> = shortcutRecordingTransition(state: recordingRecord, event: .keyPressed(commandShiftK))
        #expect(result == ShortcutRecordingTransition(state: idle, effects: [.resumeHotKeys, .assign(.record, commandShiftK)]))
    }

    @Test func escapeCancelsEvenWithModifiers() {
        for modifiers: UInt32 in [0, CarbonModifier.command] {
            let escape: KeyBinding = KeyBinding(keyCode: escapeKeyCode, modifiers: modifiers)
            let result: ShortcutRecordingTransition<Action> = shortcutRecordingTransition(state: recordingRecord, event: .keyPressed(escape))
            #expect(result == ShortcutRecordingTransition(state: idle, effects: [.resumeHotKeys]))
        }
    }

    @Test func focusLossAndDisappearanceResume() {
        #expect(shortcutRecordingTransition(state: recordingRecord, event: .focusLost) == ShortcutRecordingTransition(state: idle, effects: [.resumeHotKeys]))
        #expect(shortcutRecordingTransition(state: recordingRecord, event: .disappeared(.record)) == ShortcutRecordingTransition(state: idle, effects: [.resumeHotKeys]))
        // Başka bir eylemin kaydedicisinin kalkması süren kaydı bitirmez.
        #expect(shortcutRecordingTransition(state: recordingRecord, event: .disappeared(.dictate)) == ShortcutRecordingTransition(state: recordingRecord, effects: []))
    }

    @Test func idleEventsHaveNoEffects() {
        let events: [ShortcutRecordingEvent<Action>] = [.focusLost, .disappeared(.record), .keyPressed(commandShiftK)]
        for event in events {
            #expect(shortcutRecordingTransition(state: idle, event: event) == ShortcutRecordingTransition(state: idle, effects: []))
        }
    }

    /// Her olay dizisinde askıya alma ve yeniden kurma dengelidir: kayıt bitince kısayollar askıda kalmaz.
    @Test func suspendAndResumeAlwaysBalance() {
        let events: [ShortcutRecordingEvent<Action>] = [
            .tapped(.record), .tapped(.dictate), .disappeared(.record), .tapped(.dictate), .tapped(.record),
            .focusLost, .tapped(.record), .keyPressed(commandShiftK), .tapped(.dictate), .disappeared(.dictate),
            .tapped(.record), .keyPressed(KeyBinding(keyCode: escapeKeyCode, modifiers: 0)),
        ]
        var state: ShortcutRecordingState<Action> = idle
        var suspended: Bool = false
        for event in events {
            let result: ShortcutRecordingTransition<Action> = shortcutRecordingTransition(state: state, event: event)
            for effect in result.effects {
                switch effect {
                case .suspendHotKeys:
                    #expect(!suspended)
                    suspended = true
                case .resumeHotKeys:
                    #expect(suspended)
                    suspended = false
                case .assign:
                    #expect(!suspended)
                }
            }
            state = result.state
            #expect(suspended == (state.recording != nil))
        }
        #expect(!suspended)
    }

    @Test func sameBindingForSameActionIsUnchanged() {
        let others: [AssignedShortcut<Action>] = [AssignedShortcut(action: .dictate, binding: defaultDictateBinding)]
        #expect(shortcutChoice(action: .record, pressed: defaultRecordBinding, current: defaultRecordBinding, others: others) == .unchanged)
    }

    @Test func bindingOfAnotherActionIsTaken() {
        let others: [AssignedShortcut<Action>] = [
            AssignedShortcut(action: .record, binding: defaultRecordBinding),
            AssignedShortcut(action: .dictate, binding: defaultDictateBinding),
        ]
        #expect(shortcutChoice(action: .record, pressed: defaultDictateBinding, current: defaultRecordBinding, others: others) == .taken(by: .dictate))
        // Kısayolu kurulamamış eylem (current nil) kendi saklı kısayoluna yeniden basınca çakışma sayılmaz.
        #expect(shortcutChoice(action: .record, pressed: defaultRecordBinding, current: nil, others: others) == .available)
        #expect(shortcutChoice(action: .record, pressed: commandShiftK, current: defaultRecordBinding, others: others) == .available)
    }
}
