
import SwiftUI

@main
struct SimpleEditorApp: App {
    @State private var project = Project(name: "My Test Project test 2")
    
    var body: some Scene {
        WindowGroup {
          ProjectEditor(project: $project)
        }
    }
}
