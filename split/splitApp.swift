import SwiftUI

@main
struct splitApp: App {
    @State private var store = WorkoutStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
        }
    }
}
