import SwiftUI

@main
struct SimpleEditorApp: App {
    var body: some Scene {
        WindowGroup {
            if let url = Bundle.main.url(forResource: "output", withExtension: "mp4") {
                ProjectEditor(videoURL: url)
            } else {
                Text("Video file not found")
                    .frame(width: 400, height: 300)
            }
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 900, height: 650)
    }
}
