#if PHONE_DIALER
import AINotepadCore
import AVFoundation
import CallKit
import Foundation
import os
// The Voice SDK is Objective-C without Sendable annotations; its documented threading (delegates on main, the audio
// session block on a serial queue of ours) is followed below.
@preconcurrency import TwilioVoice
import UIKit

/// What happened to the call (from CallKit and the Voice SDK).
enum PhoneCallEvent: Equatable {
    case ringing
    case connected
    case reconnecting
    case reconnected
    /// The call ended; a message when it failed or dropped.
    case ended(String?)
}

/// The phone side of a dialer call: CallKit makes it a real call to iOS (audio session, lock screen, interruptions by
/// other calls, Bluetooth and car audio), the Twilio Voice SDK carries the audio. The provider records both sides and
/// plays the recording notice (server TwiML), so the app captures no audio itself. Outgoing calls only: no PushKit and
/// no `voip` background mode. CallKit calls this class on the main queue (`setDelegate(_:queue: nil)`), the Voice SDK
/// calls its delegate on the main queue too.
@MainActor
final class PhoneCallController: NSObject {
    private static let logger: os.Logger = os.Logger(subsystem: "com.senoldogan.AINotepad", category: "PhoneCall")

    var onEvent: (@MainActor (PhoneCallEvent) -> Void)?
    private let provider: CXProvider
    private let callController: CXCallController = CXCallController()
    private let audioDevice: DefaultAudioDevice = DefaultAudioDevice()
    /// Audio session changes run off the main thread, in order (the SDK's advice).
    private let audioQueue: DispatchQueue = DispatchQueue(label: "com.senoldogan.AINotepad.phone-audio")
    private var call: Call?
    /// The call being started: its CallKit id, Voice SDK token and the server's call id (a connect parameter).
    private var starting: (uuid: UUID, accessToken: String, callID: String)?
    /// The user ended the call here (CallKit already knows; it isn't reported again).
    private var endedLocally: Bool = false

    override init() {
        let configuration: CXProviderConfiguration = CXProviderConfiguration()
        configuration.maximumCallGroups = 1
        configuration.maximumCallsPerCallGroup = 1
        configuration.supportsVideo = false
        configuration.supportedHandleTypes = [.phoneNumber]
        // Recents would offer a call-back that opens this app without the dialer's checks.
        configuration.includesCallsInRecents = false
        provider = CXProvider(configuration: configuration)
        super.init()
        TwilioVoiceSDK.audioDevice = audioDevice
        provider.setDelegate(self, queue: nil)
    }

    /// Starts an outgoing call to `e164` through CallKit; CallKit asks back to perform it (`CXStartCallAction`).
    func start(uuid: UUID, e164: String, accessToken: String, callID: String) async throws {
        starting = (uuid, accessToken, callID)
        endedLocally = false
        let action: CXStartCallAction = CXStartCallAction(call: uuid, handle: CXHandle(type: .phoneNumber, value: e164))
        try await callController.request(CXTransaction(action: action))
    }

    func end(uuid: UUID) async throws {
        endedLocally = true
        try await callController.request(CXTransaction(action: CXEndCallAction(call: uuid)))
    }

    func setMuted(uuid: UUID, muted: Bool) async throws {
        try await callController.request(CXTransaction(action: CXSetMutedCallAction(call: uuid, muted: muted)))
    }

    /// Speaker or receiver: the SDK's audio session block reapplied with the route override.
    func setSpeaker(_ on: Bool) {
        // The SDK documents running its audio session block on a serial queue of the app; the device is only read there.
        nonisolated(unsafe) let device: DefaultAudioDevice = audioDevice
        device.block = {
            DefaultAudioDevice.DefaultAVAudioSessionConfigurationBlock()
            do {
                try AVAudioSession.sharedInstance().overrideOutputAudioPort(on ? .speaker : .none)
            } catch {
                PhoneCallController.logger.error("Audio route could not change, error: \(String(describing: error), privacy: .private)")
            }
        }
        audioQueue.async {
            device.block()
        }
        UIDevice.current.isProximityMonitoringEnabled = !on && call != nil
    }

    /// Connects the Voice SDK leg of the call CallKit is starting; false when it isn't the call being started.
    private func connect(uuid: UUID) -> Bool {
        guard let starting, starting.uuid == uuid else {
            return false
        }
        // CallKit activates the audio session; the SDK's audio starts in `didActivate`.
        audioDevice.isEnabled = false
        let options: ConnectOptions = ConnectOptions(accessToken: starting.accessToken) { (builder: ConnectOptionsBuilder) in
            builder.params = ["callId": starting.callID]
            builder.uuid = starting.uuid
        }
        call = TwilioVoiceSDK.connect(options: options, delegate: self)
        return true
    }

    private func finish(uuid: UUID?, reason: CXCallEndedReason?, message: String?) {
        if let uuid, let reason, !endedLocally {
            provider.reportCall(with: uuid, endedAt: Date(), reason: reason)
        }
        call = nil
        starting = nil
        UIDevice.current.isProximityMonitoringEnabled = false
        onEvent?(.ended(message))
    }
}

extension PhoneCallController: CXProviderDelegate {
    nonisolated func providerDidReset(_ provider: CXProvider) {
        MainActor.assumeIsolated {
            Self.logger.warning("CallKit reset the provider")
            audioDevice.isEnabled = false
            call?.disconnect()
            finish(uuid: nil, reason: nil, message: String(localized: "Arama sistem tarafından sonlandırıldı."))
        }
    }

    // CallKit's actions aren't Sendable: only their values cross into the main actor; they are fulfilled out here, on
    // the same (main) queue.
    nonisolated func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        let uuid: UUID = action.callUUID
        let connected: Bool = MainActor.assumeIsolated { connect(uuid: uuid) }
        guard connected else {
            action.fail()
            return
        }
        provider.reportOutgoingCall(with: uuid, startedConnectingAt: Date())
        action.fulfill()
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        MainActor.assumeIsolated {
            call?.disconnect()
        }
        action.fulfill()
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        let muted: Bool = action.isMuted
        MainActor.assumeIsolated {
            call?.isMuted = muted
        }
        action.fulfill()
    }

    nonisolated func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        MainActor.assumeIsolated {
            audioDevice.isEnabled = true
        }
    }

    nonisolated func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        MainActor.assumeIsolated {
            audioDevice.isEnabled = false
        }
    }
}

extension PhoneCallController: CallDelegate {
    nonisolated func callDidStartRinging(call: Call) {
        MainActor.assumeIsolated {
            onEvent?(.ringing)
        }
    }

    nonisolated func callDidConnect(call: Call) {
        MainActor.assumeIsolated {
            if let uuid = call.uuid {
                provider.reportOutgoingCall(with: uuid, connectedAt: Date())
            }
            UIDevice.current.isProximityMonitoringEnabled = true
            onEvent?(.connected)
        }
    }

    nonisolated func callDidFailToConnect(call: Call, error: any Error) {
        MainActor.assumeIsolated {
            Self.logger.error("Call failed to connect, error: \(String(describing: error), privacy: .private)")
            finish(uuid: call.uuid, reason: .failed, message: String(localized: "Arama bağlanamadı. İnternet bağlantını denetleyip yeniden dene."))
        }
    }

    nonisolated func callDidDisconnect(call: Call, error: (any Error)?) {
        MainActor.assumeIsolated {
            if let error {
                Self.logger.error("Call dropped, error: \(String(describing: error), privacy: .private)")
            }
            let message: String? = error == nil ? nil : String(localized: "Arama koptu.")
            finish(uuid: call.uuid, reason: error == nil ? .remoteEnded : .failed, message: message)
        }
    }

    nonisolated func callIsReconnecting(call: Call, error: any Error) {
        MainActor.assumeIsolated {
            Self.logger.warning("Call reconnecting, error: \(String(describing: error), privacy: .private)")
            onEvent?(.reconnecting)
        }
    }

    nonisolated func callDidReconnect(call: Call) {
        MainActor.assumeIsolated {
            onEvent?(.reconnected)
        }
    }
}
#endif
