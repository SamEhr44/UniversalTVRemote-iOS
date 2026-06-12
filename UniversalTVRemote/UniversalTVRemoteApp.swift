import SwiftUI

/// Root of the Universal TV Remote app.
///
/// Native SwiftUI port of the cross-platform Flutter "LG webOS Wi-Fi Remote".
/// The app discovers LG webOS TVs on the local Wi-Fi network, pairs with them
/// over the LG SSAP WebSocket protocol, stores the returned client-key, and
/// presents a working on-screen remote — no backend, no vendor cloud.
@main
struct UniversalTVRemoteApp: App {
    var body: some Scene {
        WindowGroup {
            ScanView()
        }
    }
}
