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

import GameController
import SwiftUI
import UIKit
import OpenEmuBase
import OpenEmuSystem
import OpenEmuKit

/// The Apple TV app.
///
/// This is a UIKit lifecycle rather than SwiftUI's `App`, for one reason: a
/// game controller only reaches the emulator when a `GCEventViewController`
/// is the root of the window, and SwiftUI makes its own root and keeps it.
/// The interface itself is still all SwiftUI — it just hangs off a root this
/// code owns, so the controller question can be answered at all.
@main
final class TVAppDelegate: UIResponder, UIApplicationDelegate {

    static func main() {
        UIApplicationMain(CommandLine.argc,
                          CommandLine.unsafeArgv,
                          nil,
                          NSStringFromClass(TVAppDelegate.self))
    }

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // tvOS will not let an app create folders inside Application Support,
        // and the engine keeps battery saves and BIOS files under there. Send
        // it to the caches folder instead, which is where tvOS wants data
        // that can be fetched again.
        OEGameCoreController.supportFolderOverride = SharingPaths.supportDirectory
            .appendingPathComponent("Engine", isDirectory: true)

        // Plugins are discovered by scanning the app bundle. This has to run
        // before any plugin is looked up.
        OECorePlugin.registerClass()
        OESystemPlugin.registerClass()

        return true
    }

    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = TVSceneDelegate.self
        return configuration
    }
}

/// Makes the window, with the controller-aware root the game needs.
final class TVSceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?

    func scene(_ scene: UIScene,
               willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }

        // The controller is tvOS's while the interface is in front. Playing a
        // game turns that off, which is what lets its buttons through.
        let root = GCEventViewController()
        root.controllerUserInteractionEnabled = true
        ControllerCapture.root = root

        let host = UIHostingController(rootView: TVHomeView())
        host.view.backgroundColor = .black
        root.addChild(host)
        host.view.frame = root.view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        root.view.addSubview(host.view)
        host.didMove(toParent: root)

        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = root
        self.window = window
        window.makeKeyAndVisible()
    }
}
