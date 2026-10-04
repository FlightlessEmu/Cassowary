// Copyright (c) 2026, OpenEmu Team
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are met:
//     * Redistributions of source code must retain the above copyright
//       notice, this list of conditions and the following disclaimer.
//     * Redistributions in binary form must reproduce the above copyright
//       notice, this list of conditions and the following disclaimer in the
//       documentation and/or other materials provided with the distribution.
//     * Neither the name of the OpenEmu Team nor the
//       names of its contributors may be used to endorse or promote products
//       derived from this software without specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY OpenEmu Team ''AS IS'' AND ANY
// EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
// WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
// DISCLAIMED. IN NO EVENT SHALL OpenEmu Team BE LIABLE FOR ANY
// DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
// (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
// LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
// ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
// SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

import SwiftUI

/// A part of the on-screen pad that can be moved and resized on its own.
enum ControlElement: String, CaseIterable {
    case dpad
    case face
    case system
    case leftShoulder
    case rightShoulder

    var title: String {
        switch self {
        case .dpad: return "Directions"
        case .face: return "Buttons"
        case .system: return "Start and Select"
        case .leftShoulder: return "Left Shoulder"
        case .rightShoulder: return "Right Shoulder"
        }
    }
}

/// Where the player has moved each part of the pad, for one system.
///
/// Each part keeps a nudge away from its usual spot and a size. The nudge is a
/// fraction of the screen, so it still lands in the same place after the
/// screen changes size. Portrait and landscape are kept apart: a spot that
/// suits one rarely suits the other.
@MainActor
final class ControlPlacementStore: ObservableObject {

    struct Placement: Codable, Equatable {
        var x: CGFloat = 0
        var y: CGFloat = 0
        var scale: CGFloat = 1
    }

    static let scaleRange: ClosedRange<CGFloat> = 0.6...1.6

    @Published private var placements: [String: Placement]
    private let defaultsKey: String

    init(systemIdentifier: String) {
        defaultsKey = "cassowary.controlPlacement.\(systemIdentifier)"
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let saved = try? JSONDecoder().decode([String: Placement].self, from: data) {
            placements = saved
        } else {
            placements = [:]
        }
    }

    func placement(for element: ControlElement, portrait: Bool) -> Placement {
        placements[Self.key(element, portrait: portrait)] ?? Placement()
    }

    func set(_ placement: Placement, for element: ControlElement, portrait: Bool) {
        placements[Self.key(element, portrait: portrait)] = placement
        save()
    }

    /// Put every part back where it started, for this orientation only.
    func reset(portrait: Bool) {
        for element in ControlElement.allCases {
            placements[Self.key(element, portrait: portrait)] = nil
        }
        save()
    }

    private static func key(_ element: ControlElement, portrait: Bool) -> String {
        "\(portrait ? "portrait" : "landscape").\(element.rawValue)"
    }

    private func save() {
        if let data = try? JSONEncoder().encode(placements) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}
