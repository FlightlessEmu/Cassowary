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

import Foundation
import OpenEmuKit

/// The video filters installed in the app, and the user's picks.
///
/// A filter is one of the shader presets bundled under `Shaders/` — the same
/// `.slangp` presets OpenEmu ships. OpenEmuKit's `OEShaderStore` finds them and
/// parses their parameters; OpenEmuShaders compiles the one in use to Metal the
/// first time it is selected.
///
/// Choices are remembered as names rather than preset IDs because the app has
/// no preset editor: it only needs to know which bundled folder to load.
/// "None" — the plain, unfiltered picture — is the absence of a name, and is
/// what a fresh install uses. Filters are the one feature where a slow device
/// notices the cost, so the app never turns one on by itself.
@MainActor
final class ShaderCatalog: ObservableObject {

    /// What one system should do, in addition to the app-wide choice.
    enum SystemChoice: Hashable {
        /// Follow the app-wide choice. This is the out-of-the-box state.
        case automatic
        /// No filter, even when the app-wide choice has one.
        case none
        /// Use the named filter.
        case shader(String)
    }

    /// The installed filters, sorted the way the Finder sorts.
    @Published private(set) var shaders: [OEShaderModel] = []

    private let store: OEShaderStore

    /// The app-wide filter choice; absent means none.
    static let globalKey = "cassowary.videoShader"

    static func systemKey(forSystemIdentifier identifier: String) -> String {
        "cassowary.videoShader." + identifier
    }

    init(store: OEShaderStore = OEShaderStore(store: .standard)) {
        self.store = store
        refresh()
    }

    /// The filter names, in the order they should be shown.
    var names: [String] { shaders.map(\.name) }

    func refresh() {
        let names = store.sortedSystemShaderNames + store.sortedCustomShaderNames
        shaders = names.compactMap { store.shader(withName: $0) }
    }

    /// The named filter, or nil for "None" and for a filter that is no longer
    /// installed.
    func shader(named name: String?) -> OEShaderModel? {
        guard let name, !name.isEmpty else { return nil }
        return shaders.first { $0.name == name }
    }

    // MARK: - The app-wide choice

    var globalShaderName: String? {
        get { Self.readName(forKey: Self.globalKey) }
        set {
            Self.writeName(newValue, forKey: Self.globalKey)
            objectWillChange.send()
        }
    }

    // MARK: - Per-system choices

    func choice(forSystem identifier: String) -> SystemChoice {
        guard let raw = UserDefaults.standard.string(forKey: Self.systemKey(forSystemIdentifier: identifier)) else {
            return .automatic
        }
        return raw.isEmpty ? .none : .shader(raw)
    }

    func setChoice(_ choice: SystemChoice, forSystem identifier: String) {
        let key = Self.systemKey(forSystemIdentifier: identifier)
        switch choice {
        case .automatic:
            UserDefaults.standard.removeObject(forKey: key)
        case .none:
            UserDefaults.standard.set("", forKey: key)
        case .shader(let name):
            UserDefaults.standard.set(name, forKey: key)
        }
        objectWillChange.send()
    }

    /// The filter a system launches with: its own choice, else the app-wide
    /// one. A pick whose filter is no longer installed reads back as none.
    func resolvedShaderName(forSystem identifier: String?) -> String? {
        guard let identifier else { return globalShaderName }
        switch choice(forSystem: identifier) {
        case .automatic:
            return globalShaderName
        case .none:
            return nil
        case .shader(let name):
            return shader(named: name)?.name
        }
    }

    // MARK: - Helpers

    private static func readName(forKey key: String) -> String? {
        guard let name = UserDefaults.standard.string(forKey: key), !name.isEmpty else { return nil }
        return name
    }

    private static func writeName(_ name: String?, forKey key: String) {
        if let name, !name.isEmpty {
            UserDefaults.standard.set(name, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}
