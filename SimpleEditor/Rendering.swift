import SwiftUI
import AVFoundation
import CoreImage
import CoreVideo
import Combine

@MainActor
class Renderer: ObservableObject {
    @Published var isLoading = false
    @Published var compositionSize: CGSize = CGSize(width: 640, height: 360)
    
    private let compositorId: String
    private let sourceAsset: AVAsset
    private let videoURL: URL
    private var currentProject = Project()
    
    private let renderQueue = DispatchQueue(label: "com.simple.renderer.export", qos: .userInitiated)
    
    init(videoURL: URL) {
        self.videoURL = videoURL
        self.compositorId = UUID().uuidString
        self.sourceAsset = AVAsset(url: videoURL)
        
        Task {
            await CustomVideoCompositor.setProject(currentProject, forId: compositorId)
        }
    }
    
    func buildComposition(isCut: Bool) async -> AVPlayerItem {
        currentProject.isCut = isCut
        await CustomVideoCompositor.updateProject(currentProject, forId: compositorId)
        
        let composition = AVMutableComposition()
        let videoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        )!
        
        guard let sourceTrack = sourceAsset.tracks(withMediaType: .video).first else {
            fatalError("No video track found in source asset")
        }
        
        // Update composition size
        await MainActor.run {
            compositionSize = sourceTrack.naturalSize
        }
        
        // Calculate time range based on cut/uncut
        let duration = sourceAsset.duration
        let timeRange: CMTimeRange
        
        if isCut {
            // Trim 3-5 seconds (let's use 4 seconds) from the start
            let trimDuration = CMTime(seconds: 4.0, preferredTimescale: 600)
            let startTime = trimDuration
            let remainingDuration = CMTimeSubtract(duration, trimDuration)
            timeRange = CMTimeRange(start: startTime, duration: remainingDuration)
        } else {
            // Use full video
            timeRange = CMTimeRange(start: .zero, duration: duration)
        }
        
        do {
            try videoTrack.insertTimeRange(
                timeRange,
                of: sourceTrack,
                at: .zero
            )
        } catch {
            fatalError("Failed to insert video track: \(error)")
        }
        
        // Handle audio track if present
        if let sourceAudioTrack = sourceAsset.tracks(withMediaType: .audio).first {
            if let audioTrack = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) {
                try? audioTrack.insertTimeRange(
                    timeRange,
                    of: sourceAudioTrack,
                    at: .zero
                )
            }
        }
        
        let videoComposition = AVMutableVideoComposition()
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        videoComposition.renderSize = sourceTrack.naturalSize
        
        let instruction = CompositorInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: timeRange.duration)
        instruction.compositorId = compositorId
        instruction.requiredSourceTrackIDs = [NSNumber(value: videoTrack.trackID)]
        
        videoComposition.instructions = [instruction]
        videoComposition.customVideoCompositorClass = CustomVideoCompositor.self
        
        let playerItem = AVPlayerItem(asset: composition)
        playerItem.videoComposition = videoComposition
        
        return playerItem
    }
    
    func cleanup() async {
        await CustomVideoCompositor.removeProject(forId: compositorId)
    }
}

// MARK: - Compositor Instruction

class CompositorInstruction: NSObject, AVVideoCompositionInstructionProtocol {
    var timeRange: CMTimeRange = .zero
    var enablePostProcessing: Bool = false
    var containsTweening: Bool = true
    var requiredSourceTrackIDs: [NSValue]?
    var passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid
    var compositorId: String = ""
}

// MARK: - Custom Video Compositor

class CustomVideoCompositor: NSObject, AVVideoCompositing {
    // MARK: - Render helpers
    private let renderQueue = DispatchQueue(label: "compositor.render", qos: .userInteractive)
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    // MARK: - Project storage actor (kept for future extensibility)
    private actor ProjectStorage {
        private var projects: [String: Project] = [:]

        func setProject(_ project: Project, forId id: String) {
            projects[id] = project
            print("📦 Project stored for compositor: \(id)")
        }

        func getProject(forId id: String) -> Project? {
            return projects[id]
        }

        func removeProject(forId id: String) {
            projects.removeValue(forKey: id)
            print("🗑️ Project removed for compositor: \(id)")
        }
    }

    private static let projectStorage = ProjectStorage()

    // MARK: - Public project API
    required override init() {
        super.init()
        print("🎬 CustomVideoCompositor initialized")
    }

    static func setProject(_ project: Project, forId id: String) async {
        await projectStorage.setProject(project, forId: id)
    }

    static func updateProject(_ project: Project, forId id: String) async {
        await projectStorage.setProject(project, forId: id)
        print("📝 Project updated for compositor: \(id)")
    }

    static func removeProject(forId id: String) async {
        await projectStorage.removeProject(forId: id)
    }

    private static func getProject(forId id: String) async -> Project? {
        return await projectStorage.getProject(forId: id)
    }

    // MARK: - AVVideoCompositing requirements
    var sourcePixelBufferAttributes: [String : Any]? {
        return [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
    }

    var requiredPixelBufferAttributesForRenderContext: [String : Any] {
        return [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
    }

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {
        print("🔄 Render context changed: \(newRenderContext.size)")
    }

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        renderQueue.async { [weak self] in
            guard let self = self else {
                request.finish(with: NSError(domain: "CustomVideoCompositor", code: -1, userInfo: [
                    NSLocalizedDescriptionKey: "Compositor deallocated"
                ]))
                return
            }

            guard let instruction = request.videoCompositionInstruction as? CompositorInstruction else {
                request.finish(with: self.makeError("Invalid instruction"))
                return
            }

            guard let outputBuffer = request.renderContext.newPixelBuffer() else {
                request.finish(with: self.makeError("Failed to create output buffer"))
                return
            }

            // Get the source video track ID
            guard let trackID = instruction.requiredSourceTrackIDs?.first as? CMPersistentTrackID else {
                request.finish(with: self.makeError("No source track ID"))
                return
            }

            // Get the source pixel buffer
            guard let sourceBuffer = request.sourceFrame(byTrackID: trackID) else {
                request.finish(with: self.makeError("Failed to get source frame"))
                return
            }

            // Simply copy the source frame to the output
            self.copyPixelBuffer(from: sourceBuffer, to: outputBuffer)

            let seconds = CMTimeGetSeconds(request.compositionTime)
            print("🎬 Frame at \(String(format: "%.2f", seconds))s")

            request.finish(withComposedVideoFrame: outputBuffer)
        }
    }

    func cancelAllPendingVideoCompositionRequests() {
        renderQueue.sync(flags: .barrier) {
            print("🛑 Cancelling all pending requests")
        }
    }

    // MARK: - Rendering helpers
    
    private func copyPixelBuffer(from source: CVPixelBuffer, to destination: CVPixelBuffer) {
        let sourceImage = CIImage(cvPixelBuffer: source)
        let outputRect = CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(destination), height: CVPixelBufferGetHeight(destination))
        
        CVPixelBufferLockBaseAddress(destination, [])
        defer { CVPixelBufferUnlockBaseAddress(destination, []) }
        
        ciContext.render(sourceImage, to: destination, bounds: outputRect, colorSpace: CGColorSpaceCreateDeviceRGB())
    }

    // MARK: - Utilities
    private func makeError(_ message: String) -> NSError {
        print("❌ Compositor error: \(message)")
        return NSError(domain: "CustomVideoCompositor", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

// MARK: - Supporting Types

enum VideoCompositionError: Error, LocalizedError {
    case noValidVideos
    case trackCreationFailed
    case exportFailed
    case invalidFormat
    
    var errorDescription: String? {
        switch self {
        case .noValidVideos:
            return "No valid video tracks found"
        case .trackCreationFailed:
            return "Failed to create or process video track"
        case .exportFailed:
            return "Video export failed"
        case .invalidFormat:
            return "Invalid video format"
        }
    }
}
