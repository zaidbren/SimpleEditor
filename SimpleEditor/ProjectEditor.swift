import SwiftUI
import Foundation
import AppKit
import Combine
import AVKit

struct Project: Equatable {
    var isCut: Bool = false
    var id = UUID()
}

struct ProjectEditor: View {
    @StateObject private var renderer: Renderer
    @State private var player: AVPlayer?
    @State private var project = Project(isCut: false)
    
    init(videoURL: URL) {
        _renderer = StateObject(wrappedValue: Renderer(videoURL: videoURL))
    }
    
    var body: some View {
        VStack(spacing: 20) {
            if let player {
                VideoPlayer(player: player)
                    .aspectRatio(calculateAspectRatio(), contentMode: .fit)
                    .frame(maxWidth: 800, maxHeight: 450)
                    .onAppear {
                        player.play()
                    }
            } else {
                Rectangle()
                    .fill(Color.gray.opacity(0.3))
                    .aspectRatio(16/9, contentMode: .fit)
                    .frame(maxWidth: 800, maxHeight: 450)
                    .overlay(Text("Loading..."))
            }
            
            HStack(spacing: 12) {
                Button {
                    project.isCut = true
                } label: {
                    Label("Cut", systemImage: "scissors")
                }
                .buttonStyle(.bordered)
                .tint(project.isCut ? .blue : .gray)

                Button {
                    project.isCut = false
                } label: {
                    Label("Uncut", systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(.bordered)
                .tint(!project.isCut ? .blue : .gray)
            }
        
            Text(project.isCut ? "3-5 seconds trimmed from video" : "Full video")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .padding()
        .onDisappear {
            Task {
                await renderer.cleanup()
            }
        }
        .onAppear {
            Task {
                await buildInitialComposition()
            }
        }
        .onChange(of: project) { oldValue, newValue in
            Task {
                await rebuildComposition()
            }
        }
    }
    
    private func calculateAspectRatio() -> CGFloat {
        let size = renderer.compositionSize
        guard size.width > 0 && size.height > 0 else {
            return 16/9
        }
        return size.width / size.height
    }
    
    private func buildInitialComposition() async {
        let playerItem = await renderer.buildComposition(isCut: project.isCut)
        player = AVPlayer(playerItem: playerItem)
    }
    
    private func rebuildComposition() async {
        let playerItem = await renderer.buildComposition(isCut: project.isCut)
        
        // Replace the player item
        await MainActor.run {
            player?.replaceCurrentItem(with: playerItem)
            player?.seek(to: .zero)
            player?.play()
        }
    }
}
