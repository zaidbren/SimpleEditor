import SwiftUI
import Foundation
import AppKit
import Combine
import AVKit

enum AspectRatio: Equatable {
    case landscape   // 16:9
    case portrait    // 9:16

    var value: CGFloat {
        switch self {
        case .landscape:
            return 16.0 / 9.0
        case .portrait:
            return 9.0 / 16.0
        }
    }
}

struct Project: Equatable {
    var backgroundColor: CIColor
    var aspectRatio: AspectRatio = .landscape
    var id = UUID()

    static func == (lhs: Project, rhs: Project) -> Bool {
        return lhs.backgroundColor.red == rhs.backgroundColor.red &&
               lhs.backgroundColor.green == rhs.backgroundColor.green &&
               lhs.backgroundColor.blue == rhs.backgroundColor.blue &&
               lhs.backgroundColor.alpha == rhs.backgroundColor.alpha &&
               lhs.aspectRatio == rhs.aspectRatio
    }
}

struct ProjectEditor: View {
    @StateObject private var renderer: Renderer
    @State private var selectedColor: Color = .red
    @State private var player: AVPlayer?
    
    @State private var isImporting = false
    
    @State private var project = Project(
        backgroundColor: CIColor(red: 1, green: 0, blue: 0, alpha: 1),
        aspectRatio: .landscape
    )

    
    init(videoURL: URL) {
        let initialProject = Project(backgroundColor: CIColor(red: 1, green: 0, blue: 0, alpha: 1), aspectRatio: .landscape)
        _renderer = StateObject(wrappedValue: Renderer(project: initialProject, videoURL: videoURL))
    }
    
    var body: some View {
        VStack(spacing: 20) {
            if let player {
                VideoPlayer(player: player)
                    .aspectRatio(project.aspectRatio.value, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .onAppear {
                        player.play()
                    }
            } else {
                Rectangle()
                    .fill(Color.gray.opacity(0.3))
                    .aspectRatio(project.aspectRatio.value, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .overlay(Text("Loading..."))
            }
            
            
            HStack(spacing: 12) {
                Button {
                    project.aspectRatio = .landscape
                } label: {
                    Label("Landscape", systemImage: "rectangle")
                }
                .buttonStyle(.bordered)
                .tint(project.aspectRatio == .landscape ? .blue : .gray)

                Button {
                    project.aspectRatio = .portrait
                } label: {
                    Label("Portrait", systemImage: "rectangle.portrait")
                }
                .buttonStyle(.bordered)
                .tint(project.aspectRatio == .portrait ? .blue : .gray)
            }
        
            Text("Try changing aspect ratio of the video player")
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
        .onChange(of: project) { oldValue, newValue in
            Task {
                await renderer.updateProject(newValue)
                renderer.forceRefresh()
            }
        }
    }
    
    
    private func getOrCreatePlayer(with playerItem: AVPlayerItem) -> AVPlayer {
        if let existingPlayer = player {
            return existingPlayer
        }
        let newPlayer = AVPlayer(playerItem: playerItem)
        player = newPlayer
        return newPlayer
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
