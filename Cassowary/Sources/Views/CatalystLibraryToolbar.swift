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

#if targetEnvironment(macCatalyst)
import SwiftUI
import UIKit

extension Notification.Name {
    static let addGames = Notification.Name("org.cassowary.addGames")
    static let searchGames = Notification.Name("org.cassowary.searchGames")
    static let sortGames = Notification.Name("org.cassowary.sortGames")
}

/// The Mac library's controls belong in the window toolbar, above the content.
struct CatalystLibraryToolbar: UIViewRepresentable {
    let title: String
    let isPlaying: Bool
    @Binding var searchText: String
    let sortOptions: [(String, String)]
    let selectedSort: String
    let onSort: (String) -> Void
    let onAdd: () -> Void
    let onRefresh: () -> Void
    let onToggleSidebar: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WindowView {
        let view = WindowView()
        view.coordinator = context.coordinator
        return view
    }

    func updateUIView(_ uiView: WindowView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.update(window: uiView.window)
    }

    final class WindowView: UIView {
        weak var coordinator: Coordinator?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            coordinator?.update(window: window)
        }
    }

    final class Coordinator: NSObject, NSToolbarDelegate {
        var parent: CatalystLibraryToolbar
        private var toolbar: NSToolbar?
        private var searchField: UISearchTextField?
        private var sortItem: NSMenuToolbarItem?
        private let sidebarID = NSToolbarItem.Identifier("cassowary.sidebar")
        private let addID = NSToolbarItem.Identifier("cassowary.add")
        private let sortID = NSToolbarItem.Identifier("cassowary.sort")
        private let refreshID = NSToolbarItem.Identifier("cassowary.refresh")
        private let searchID = NSToolbarItem.Identifier("cassowary.search")

        init(_ parent: CatalystLibraryToolbar) {
            self.parent = parent
            super.init()
            NotificationCenter.default.addObserver(self, selector: #selector(focusSearch),
                                                   name: .searchGames, object: nil)
        }

        deinit { NotificationCenter.default.removeObserver(self) }

        func update(window: UIWindow?) {
            guard let scene = window?.windowScene, let titlebar = scene.titlebar else { return }
            if parent.isPlaying {
                titlebar.toolbar = nil
                titlebar.titleVisibility = .hidden
                return
            }
            scene.title = parent.title
            titlebar.titleVisibility = .visible
            titlebar.toolbarStyle = .unifiedCompact
            if toolbar == nil {
                let toolbar = NSToolbar(identifier: "cassowary.library")
                toolbar.delegate = self
                toolbar.displayMode = .iconOnly
                toolbar.allowsUserCustomization = false
                self.toolbar = toolbar
            }
            titlebar.toolbar = toolbar
            if searchField?.text != parent.searchText { searchField?.text = parent.searchText }
            sortItem?.itemMenu = sortMenu()
        }

        func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
            [sidebarID, .primarySidebarTrackingSeparatorItemIdentifier, .flexibleSpace,
             addID, sortID, refreshID, .space, searchID]
        }

        func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
            toolbarDefaultItemIdentifiers(toolbar)
        }

        func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                     willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
            if identifier == searchID {
                let field = UISearchTextField()
                field.placeholder = "Search games"
                field.text = parent.searchText
                field.addTarget(self, action: #selector(searchChanged(_:)), for: .editingChanged)
                field.widthAnchor.constraint(equalToConstant: 220).isActive = true
                searchField = field
                let item = NSUIViewToolbarItem(itemIdentifier: identifier, uiView: field)
                item.label = "Search games"
                return item
            }
            if identifier == sortID {
                let item = NSMenuToolbarItem(itemIdentifier: identifier)
                item.label = "Sort"
                item.image = UIImage(systemName: "arrow.up.arrow.down")
                item.itemMenu = sortMenu()
                sortItem = item
                return item
            }
            let label: String
            let symbol: String
            let action: Selector
            switch identifier {
            case sidebarID: (label, symbol, action) = ("Show or Hide Systems", "sidebar.left", #selector(toggleSidebar))
            case addID: (label, symbol, action) = ("Add Games", "plus", #selector(add))
            case refreshID: (label, symbol, action) = ("Refresh", "arrow.clockwise", #selector(refresh))
            default: return nil
            }
            let button = UIBarButtonItem(image: UIImage(systemName: symbol), style: .plain,
                                         target: self, action: action)
            let item = NSToolbarItem(itemIdentifier: identifier, barButtonItem: button)
            item.label = label
            item.toolTip = label
            item.isNavigational = identifier == sidebarID
            return item
        }

        private func sortMenu() -> UIMenu {
            UIMenu(title: "Sort by", children: parent.sortOptions.map { value, label in
                UIAction(title: label, state: value == parent.selectedSort ? .on : .off) { [weak self] _ in
                    self?.parent.onSort(value)
                }
            })
        }

        @objc private func searchChanged(_ sender: UISearchTextField) { parent.searchText = sender.text ?? "" }
        @objc private func focusSearch() {
            // A native toolbar hosts this field in a separate UIKit window;
            // that host isn't the scene's key content window.
            guard !parent.isPlaying else { return }
            searchField?.becomeFirstResponder()
        }
        @objc private func toggleSidebar() { parent.onToggleSidebar() }
        @objc private func add() { parent.onAdd() }
        @objc private func refresh() { parent.onRefresh() }
    }
}
#endif
