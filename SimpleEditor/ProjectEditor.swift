import SwiftUI
import AVKit
import Combine

struct Project: Equatable {
    var name: String
}

struct ProjectEditor: View {
    @Binding var project: Project
    
    @StateObject private var playerViewModel: VideoPlayerViewModel
    
    init(project: Binding<Project>) {
        self._project = project
        
        _playerViewModel = StateObject(wrappedValue: VideoPlayerViewModel(project: project))
    }
    
    var body: some View {
        VStack(spacing: 20) {
            Form {
                videoPlayerSection
                
            }
        }
        .padding()
        .frame(minWidth: 600, minHeight: 500)
        .task {
            await playerViewModel.loadVideo()
        }
        .onChange(of: project) { oldValue, newValue in
            Task {
                await playerViewModel.updateProject(project)
            }
        }

        .onDisappear {
            playerViewModel.cleanup()
        }
    }
    
    
    
    private var videoPlayerSection: some View {
        Section("Video Preview") {
            VStack(spacing: 12) {
                if playerViewModel.isLoading {
                    ProgressView("Loading video...")
                        .frame(height: 300)
                } else if let error = playerViewModel.error {
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle)
                            .foregroundStyle(.red)
                        Text("Error: \(error.localizedDescription)")
                            .foregroundStyle(.secondary)
                        
                        Button("Retry") {
                            Task { await playerViewModel.loadVideo() }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .frame(height: 300)
                } else if playerViewModel.hasVideo {
                    VideoPlayer(player: playerViewModel.player)
                        .frame(height: 400)
                        .cornerRadius(8)
                    
                    HStack(spacing: 16) {
                        Button(action: { playerViewModel.play() }) {
                            Label("Play", systemImage: "play.fill")
                        }
                        
                        Button(action: { playerViewModel.pause() }) {
                            Label("Pause", systemImage: "pause.fill")
                        }
                        
                        Button(action: { playerViewModel.reset() }) {
                            Label("Reset", systemImage: "arrow.counterclockwise")
                        }
                        
                        Spacer()
                        
                        Button(action: {
                            Task { await playerViewModel.loadVideo() }
                        }) {
                            Label("Reload", systemImage: "arrow.clockwise")
                        }
                        
                        Button("Export the video") {
                            Task {
                                let tempDir = FileManager.default.temporaryDirectory
                                let outputURL = tempDir.appendingPathComponent("exported_video.mp4")
                                print("Exporting to:", outputURL.path)
                                await playerViewModel.exportVideo(outputURL)
                                print("Export successful! Saved at:", outputURL)
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                    .buttonStyle(.bordered)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "video.slash")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("No video composition loaded")
                            .foregroundStyle(.secondary)
                        
                        Button("Load Video") {
                            Task { await playerViewModel.loadVideo() }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .frame(height: 300)
                }
            }
        }
    }
    
}

// MARK: - Video Player ViewModel

@MainActor
class VideoPlayerViewModel: ObservableObject {
    @Published var isLoading = false
    @Published var error: Error?
    @Published var hasVideo = false
    
    let player = AVPlayer()
    private let renderer: Renderer
    
    init(project: Binding<Project>) {
        self.renderer = Renderer(project: project.wrappedValue)
    }
    
    func updateProject(_ project: Project) async {
        await renderer.updateProject(project)
    }
    
    func exportVideo(_ outputURL: URL) async {
        do {
            try await renderer.exportVideo(to: outputURL)
            print("Export successful! to \(outputURL)")
        } catch {
            print("Export failed:", error)
        }
    }
    
    func loadVideo() async {
        isLoading = true
        error = nil
        hasVideo = false
        
        await renderer.buildComposition()
        
        error = renderer.error
        
        if let playerItem = renderer.playerItem {
            player.replaceCurrentItem(with: playerItem)
            hasVideo = true
        }
        
        isLoading = false
    }
    
    func play() {
        player.play()
    }
    
    func pause() {
        player.pause()
    }
    
    func reset() {
        player.seek(to: .zero)
        player.pause()
    }
    
    func cleanup() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            await self.renderer.cleanup()
        }
    }
    
    nonisolated deinit {
        let playerToClean = player
        let rendererToClean = renderer
        
        Task { @MainActor in
            playerToClean.pause()
            playerToClean.replaceCurrentItem(with: nil)
            await rendererToClean.cleanup()
        }
    }
}
