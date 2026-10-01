// Copyright (c) 2026, Cassowary contributors
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are met:
//     * Redistributions of source code must retain the above copyright
//       notice, this list of conditions and the following disclaimer.
//     * Redistributions in binary form must reproduce the above copyright
//       notice, this list of conditions and the following disclaimer in the
//       documentation and/or other materials provided with the distribution.
//     * Neither the name of the Cassowary contributors nor the
//       names of its contributors may be used to endorse or promote products
//       derived from this software without specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY Cassowary contributors ''AS IS'' AND ANY
// EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
// WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
// DISCLAIMED. IN NO EVENT SHALL Cassowary contributors BE LIABLE FOR ANY
// DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
// (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
// LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
// ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
// SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

import AVFoundation
import Combine
import OpenEmuBase

/// The app's half of a game's microphone (see `OEMicrophoneInput`).
///
/// A Nintendo DS game can listen: blow to put out candles, talk to a puppy.
/// The core says when it is listening; this captures sound only then, so
/// nobody is asked for the microphone who never plays such a game, and the
/// audio session only changes while a game is listening. Where there is no
/// microphone (the Apple TV), or permission was refused, `blow()` stands in.
@MainActor
final class MicrophoneCapture: ObservableObject {

    static let shared = MicrophoneCapture()

    /// Whether the running game is listening, for showing a Blow button.
    @Published private(set) var isListening = false

    private var observer: NSObjectProtocol?
    private var blowTask: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?

    /// How long a game must stay quiet before the microphone is let go.
    /// melonDS stops listening after two frames without a read, and some
    /// games read in bursts, so without this the microphone (and the Blow
    /// button) would flicker on and off.
    private static let stopDelay: Duration = .seconds(2)

    #if os(iOS)
    private let engine = AVAudioEngine()
    private var capturing = false
    private var previousCategory: AVAudioSession.Category?
    #endif

    func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: .OEMicrophoneInputListeningDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.listeningChanged() }
        }

        #if DEBUG
        // Acts as if a game started listening, to check the Blow buttons and
        // the permission request without a DS game that uses the
        // microphone. Only set from the command line.
        if UserDefaults.standard.bool(forKey: "cassowary.testMicrophoneListening") {
            OEMicrophoneInput.shared.startListening()
        }
        #endif
    }

    /// Blow into the microphone for a moment: loud noise, which is what
    /// blowing sounds like to a game.
    func blow(for duration: Duration = .seconds(1.5)) {
        blowTask?.cancel()
        setBlowing(true)
        blowTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.setBlowing(false)
        }
    }

    /// Blowing while a button is held, for the phone's on-screen control.
    func setBlowing(_ blowing: Bool) {
        if !blowing { blowTask?.cancel() }
        OEMicrophoneInput.shared.blowing = blowing
    }

    private func listeningChanged() {
        if OEMicrophoneInput.shared.isListening {
            stopTask?.cancel()
            stopTask = nil
            guard !isListening else { return }
            isListening = true
            #if os(iOS)
            beginCapture()
            #endif
        } else {
            guard isListening, stopTask == nil else { return }
            stopTask = Task { [weak self] in
                try? await Task.sleep(for: Self.stopDelay)
                guard !Task.isCancelled else { return }
                self?.stopListening()
            }
        }
    }

    /// The game is closing: let go of the microphone now rather than after
    /// the delay, and drop anything a held Mic button left behind.
    func gameStopped() {
        stopTask?.cancel()
        OEMicrophoneInput.shared.stopListening()
        stopListening()
    }

    private func stopListening() {
        stopTask = nil
        guard !OEMicrophoneInput.shared.isListening else { return }
        isListening = false
        setBlowing(false)
        #if os(iOS)
        endCapture()
        #endif
    }

    #if os(iOS)
    // MARK: - Capturing

    private func beginCapture() {
        guard !capturing else { return }
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            break
        case .undetermined:
            AVAudioApplication.requestRecordPermission { [weak self] granted in
                Task { @MainActor in
                    if granted, self?.isListening == true { self?.beginCapture() }
                }
            }
            return
        default:
            // Refused: the Blow button still works.
            return
        }

        let session = AVAudioSession.sharedInstance()
        previousCategory = session.category
        do {
            // Play and record, speaker first, and leave Bluetooth headphones
            // on their good playback profile rather than the call one.
            try session.setCategory(.playAndRecord, options: [.defaultToSpeaker, .allowBluetoothA2DP, .mixWithOthers])
            try session.setActive(true)
        } catch {
            NSLog("[Cassowary] microphone: could not set up the audio session: %@", error.localizedDescription)
            return
        }

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0,
              let target = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                         sampleRate: OEMicrophoneInput.sampleRate,
                                         channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: inputFormat, to: target)
        else {
            NSLog("[Cassowary] microphone: no input to listen to")
            restoreSession()
            return
        }

        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { buffer, _ in
            Self.forward(buffer, converter: converter, target: target)
        }
        do {
            try engine.start()
            capturing = true
            NSLog("[Cassowary] microphone: listening")
        } catch {
            input.removeTap(onBus: 0)
            restoreSession()
            NSLog("[Cassowary] microphone: could not start: %@", error.localizedDescription)
        }
    }

    private func endCapture() {
        guard capturing else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        capturing = false
        restoreSession()
        NSLog("[Cassowary] microphone: stopped")
    }

    private func restoreSession() {
        guard let previousCategory else { return }
        try? AVAudioSession.sharedInstance().setCategory(previousCategory)
        self.previousCategory = nil
    }

    /// Converts a captured buffer to the core's format and hands it over.
    /// Runs on the audio thread.
    private nonisolated static func forward(_ buffer: AVAudioPCMBuffer,
                                            converter: AVAudioConverter,
                                            target: AVAudioFormat) {
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }

        var consumed = false
        var error: NSError?
        converter.convert(to: converted, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let samples = converted.int16ChannelData?[0] else { return }
        OEMicrophoneInput.shared.appendSamples(samples, count: UInt(converted.frameLength))
    }
    #endif
}
