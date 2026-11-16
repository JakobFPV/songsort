import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Group {
            switch app.route {
            case .launching:
                ProgressView()
            case .loggedOut:
                LoginView()
            case .home:
                HomeView()
            }
        }
        .animation(.default, value: app.route)
    }
}
