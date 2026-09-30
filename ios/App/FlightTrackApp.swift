import SwiftUI

@main
struct FlightTrackApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            FlightListView()
                .environment(model)
                .preferredColorScheme(.dark)
                .onOpenURL { model.handle(url: $0) }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: Task { await model.sceneBecameActive() }
            case .background: model.sceneEnteredBackground()
            default: break
            }
        }
        .backgroundTask(.appRefresh(AppConfig.refreshTaskID)) {
            await model.backgroundRefresh()
        }
    }
}
