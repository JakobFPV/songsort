import SwiftUI

@main
struct SongSortApp: App {
    @State private var model = AppModel(environment: AppEnvironment.make())
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .task { await model.start() }
                .onOpenURL { url in model.handleOpenURL(url) }
        }
        .onChange(of: scenePhase) { _, phase in
            model.scenePhaseChanged(phase)
        }
    }
}
