import SwiftUI
import Foundation
import AppKit
import Combine
import AVKit

struct Project: Equatable {
    var backgroundColor: CIColor
    var id = UUID()
    
    static func == (lhs: Project, rhs: Project) -> Bool {
        return lhs.backgroundColor.red == rhs.backgroundColor.red &&
               lhs.backgroundColor.green == rhs.backgroundColor.green &&
               lhs.backgroundColor.blue == rhs.backgroundColor.blue &&
               lhs.backgroundColor.alpha == rhs.backgroundColor.alpha
    }
}

struct ProjectEditor: View {
    @StateObject private var renderer: Renderer
    @State private var selectedColor: Color = .red
    @State private var player: AVPlayer?
    
    @State private var isImporting = false

    
    init(videoURL: URL) {
        let initialProject = Project(backgroundColor: CIColor(red: 1, green: 0, blue: 0, alpha: 1))
        _renderer = StateObject(wrappedValue: Renderer(project: initialProject, videoURL: videoURL))
    }
    
    var body: some View {
            VStack(spacing: 20) {
                if let player {
                    VideoPlayer(player: player)
                        .frame(height: 400)
                        .onAppear {
                            player.play()
                        }
                } else {
                    Rectangle()
                        .fill(Color.gray.opacity(0.3))
                        .frame(height: 400)
                        .overlay(Text("Loading..."))
                }
                
//                VStack(spacing: 15) {
//                    Text("Background Color")
//                        .font(.headline)
//                    
//                    ColorPicker("Select Color", selection: $selectedColor)
//                        .padding(.horizontal)
//                    
//                    Button("Update Color") {
//                        updateColor()
//                    }
//                    .buttonStyle(.borderedProminent)
//                    
//                    HStack(spacing: 10) {
//                        ColorButton(color: .red) { updateColor(to: .red) }
//                        ColorButton(color: .green) { updateColor(to: .green) }
//                        ColorButton(color: .blue) { updateColor(to: .blue) }
//                        ColorButton(color: .yellow) { updateColor(to: .yellow) }
//                        ColorButton(color: .purple) { updateColor(to: .purple) }
//                    }
//                }
//                .padding()
//                .background(Color.gray.opacity(0.1))
//                .cornerRadius(10)
                VStack {
                    Button("Import your video") {
                        isImporting = true
                    }
                }
                .padding()
                
                Text("💡 Try importing a 30 second video")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            .onDisappear {
                Task {
                    await renderer.cleanup()
                }
            }
            .onAppear {
                if let playerItem = renderer.playerItem {
                    player = getOrCreatePlayer(with: playerItem)
                }
            }
            .fileImporter(
                        isPresented: $isImporting,
                        allowedContentTypes: [.movie, .video],
                        allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    handlePickedVideo(url)
                case .failure(let error):
                    print("File import error:", error)
                }
            }
        }
    
    private func handlePickedVideo(_ url: URL) {
            guard url.startAccessingSecurityScopedResource() else {
                print("Failed to access security-scoped resource")
                return
            }

            let asset = AVURLAsset(url: url)
            let videoTracks = asset.tracks(withMediaType: .video)

            guard let firstVideoTrack = videoTracks.first else {
                print("No video track found")
                url.stopAccessingSecurityScopedResource()
                return
            }

            renderer.insertUserVideoTrack(from: asset, track: firstVideoTrack)

            url.stopAccessingSecurityScopedResource()
        }
    
    private func getOrCreatePlayer(with playerItem: AVPlayerItem) -> AVPlayer {
        if let existingPlayer = player {
            return existingPlayer
        }
        let newPlayer = AVPlayer(playerItem: playerItem)
        player = newPlayer
        return newPlayer
    }
    
    private func updateColor(to color: Color? = nil) {
            let targetColor = color ?? selectedColor
            let uiColor = NSColor(targetColor)
            let ciColor = CIColor(color: uiColor) ?? CIColor(red: 0, green: 0, blue: 0, alpha: 1)
            
            print("🎨 UI: Updating color to R:\(ciColor.red) G:\(ciColor.green) B:\(ciColor.blue)")
           
            
            Task { @MainActor in
                let newProject = Project(backgroundColor: ciColor)
                await renderer.updateProject(newProject)
                // Force the video composition to trigger cache invalidation
                renderer.forceRefresh()
                // Force the video to re-render by seeking to current time
                if let player = player {
                    let currentTime = player.currentTime()
                    let wasPlaying = player.rate > 0
                    
                    await player.seek(to: currentTime, toleranceBefore: .zero, toleranceAfter: .zero)
                    
                    // Resume playback if it was playing
                    if wasPlaying {
                        player.play()
                    }
                    
                    print("✅ UI: Sought to \(CMTimeGetSeconds(currentTime))s to refresh frame")
                }
            }
        }
}

struct ColorButton: View {
    let color: Color
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: 8)
                .fill(color)
                .frame(width: 50, height: 50)
        }
    }
}
