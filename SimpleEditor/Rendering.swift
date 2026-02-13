import SwiftUI
import AVFoundation
import CoreImage
import CoreVideo
import Combine

@MainActor
class Renderer: ObservableObject {
    @Published var playerItem: AVPlayerItem?
    @Published var isLoading = false
    
    
    private var project: Project
    private let compositorId: String
    private let composition: AVMutableComposition
    private var videoComposition: AVMutableVideoComposition
    private let sourceAsset: AVAsset
    
    private let renderQueue = DispatchQueue(label: "com.simple.renderer.export", qos: .userInitiated)
    
    init(project: Project, videoURL: URL) {
        self.project = project
        self.compositorId = UUID().uuidString
        
        let asset = AVAsset(url: videoURL)
        self.sourceAsset = asset
        
        let composition = AVMutableComposition()
        let videoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        )!
        
        guard let sourceTrack = asset.tracks(withMediaType: .video).first else {
            fatalError("No video track found in source asset")
        }
        
        do {
            try videoTrack.insertTimeRange(
                CMTimeRange(start: .zero, duration: asset.duration),
                of: sourceTrack,
                at: .zero
            )
        } catch {
            fatalError("Failed to insert video track: \(error)")
        }
        
        // Handle audio track if present
        if let sourceAudioTrack = asset.tracks(withMediaType: .audio).first {
            if let audioTrack = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) {
                try? audioTrack.insertTimeRange(
                    CMTimeRange(start: .zero, duration: asset.duration),
                    of: sourceAudioTrack,
                    at: .zero
                )
            }
        }
        
        let videoComposition = AVMutableVideoComposition()
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        videoComposition.renderSize = sourceTrack.naturalSize
        
        let instruction = CompositorInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: asset.duration)
        instruction.compositorId = compositorId
        instruction.requiredSourceTrackIDs = [NSNumber(value: videoTrack.trackID)]
        
        videoComposition.instructions = [instruction]
        videoComposition.customVideoCompositorClass = CustomVideoCompositor.self
        
        self.composition = composition
        self.videoComposition = videoComposition
        
        Task {
            await CustomVideoCompositor.setProject(project, forId: compositorId)
        }
        
        let playerItem = AVPlayerItem(asset: composition)
        playerItem.videoComposition = videoComposition
        self.playerItem = playerItem
    }
    
    private func updateAspectRatio() {
        guard let oldVideoComposition = videoComposition as? AVMutableVideoComposition else {
            return
        }

        let renderSize: CGSize

        switch project.aspectRatio {
        case .landscape:
            renderSize = CGSize(width: 1920, height: 1080)

        case .portrait:
            renderSize = CGSize(width: 1080, height: 1920)
        }

        // Create a new mutable composition
        let newVideoComposition = AVMutableVideoComposition()
        newVideoComposition.frameDuration = oldVideoComposition.frameDuration
        newVideoComposition.renderSize = renderSize
        newVideoComposition.instructions = oldVideoComposition.instructions
        newVideoComposition.customVideoCompositorClass =
            oldVideoComposition.customVideoCompositorClass

        self.videoComposition = newVideoComposition

        print("Updated render size to: \(Int(renderSize.width)) x \(Int(renderSize.height))")
    }
    
    func updateProject(_ project: Project) async {
        let oldAspectRatio = self.project.aspectRatio
        
        self.project = project
        await CustomVideoCompositor.updateProject(project, forId: compositorId)
        
        // Update aspect ratio if it changed
        if oldAspectRatio != project.aspectRatio {
            updateAspectRatio()
            forceRefresh()
        }
    }
    
    func forceRefresh() {
        guard let playerItem = playerItem else { return }
        // Force a refresh by reassigning the video composition
        let temp = playerItem.videoComposition
        playerItem.videoComposition = nil
        playerItem.videoComposition = temp
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

    // MARK: - Project storage actor
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

    // MARK: - Cached image (loaded once)
    private static let cachedDogImage: CIImage? = {
        guard let url = Bundle.main.url(forResource: "dog", withExtension: "jpg") else {
            print("❌ dog.jpg not found in bundle")
            return nil
        }
        guard let img = CIImage(contentsOf: url) else {
            print("❌ Failed to create CIImage from dog.jpg")
            return nil
        }
        print("🐶 dog.jpg loaded and cached for compositor")
        return img
    }()

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
        // We do not store the AV render context — we use our own CIContext for rendering to pixel buffers.
    }

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        renderQueue.async { [weak self] in
            // If compositor was deallocated, finish with an error
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

            let compositorId = instruction.compositorId
            let compositionTime = request.compositionTime
            let seconds = CMTimeGetSeconds(compositionTime)

            // Use a Task to await async project retrieval without blocking the render queue
            Task {
                guard let project = await CustomVideoCompositor.getProject(forId: compositorId) else {
                    request.finish(with: self.makeError("No project found for ID: \(compositorId)"))
                    return
                }

                // Render background + centered image (or fallback to solid color)
                if let dogImage = CustomVideoCompositor.cachedDogImage {
                    self.renderBackgroundAndCenteredImage(
                        backgroundColor: project.backgroundColor,
                        image: dogImage,
                        into: outputBuffer
                    )
                } else {
                    self.renderSolidColor(project.backgroundColor, to: outputBuffer)
                }

                print("🎨 Frame at \(String(format: "%.2f", seconds))s - Color: R:\(project.backgroundColor.red) G:\(project.backgroundColor.green) B:\(project.backgroundColor.blue)")

                request.finish(withComposedVideoFrame: outputBuffer)
            }
        }
    }

    func cancelAllPendingVideoCompositionRequests() {
        renderQueue.sync(flags: .barrier) {
            print("🛑 Cancelling all pending requests")
        }
    }

    // MARK: - Rendering helpers

    /// Renders a background filled with `color` and then draws `image` aspect-fit and centered on top of it.
    /// - Parameters:
    ///   - backgroundColor: CIColor used to fill the background.
    ///   - image: CIImage to be drawn centered and aspect-fit.
    ///   - pixelBuffer: The destination CVPixelBuffer to render into.
    private func renderBackgroundAndCenteredImage(backgroundColor: CIColor, image: CIImage, into pixelBuffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        let outputWidth = CVPixelBufferGetWidth(pixelBuffer)
        let outputHeight = CVPixelBufferGetHeight(pixelBuffer)
        let outputSize = CGSize(width: outputWidth, height: outputHeight)
        let outputRect = CGRect(origin: .zero, size: outputSize)

        // Create solid background CIImage (cropped to output rect)
        let bgImage = CIImage(color: backgroundColor).cropped(to: outputRect)

        // Compute aspect-fit scale for the source image
        let sourceSize = image.extent.size
        guard sourceSize.width > 0 && sourceSize.height > 0 else {
            // Fallback: just render background if image invalid
            ciContext.render(bgImage, to: pixelBuffer, bounds: outputRect, colorSpace: CGColorSpaceCreateDeviceRGB())
            return
        }

        let scale = min(outputSize.width / sourceSize.width, outputSize.height / sourceSize.height)
        let scaledSize = CGSize(width: sourceSize.width * scale, height: sourceSize.height * scale)

        // Position (top-left origin = (0,0) in Core Image coordinate space for rendering to pixel buffer)
        // We want to place the scaled image centered in the output
        let x = (outputSize.width - scaledSize.width) / 2.0
        let y = (outputSize.height - scaledSize.height) / 2.0

        // Apply scale, then translation in two steps to avoid transform order confusion
        let scaledImage = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let translatedImage = scaledImage.transformed(by: CGAffineTransform(translationX: x, y: y))

        // Composite the translated image over the background
        let composed = translatedImage.composited(over: bgImage)

        // Render composed image into the pixel buffer
        ciContext.render(composed, to: pixelBuffer, bounds: outputRect, colorSpace: CGColorSpaceCreateDeviceRGB())
    }

    /// Legacy/fallback: fills the pixel buffer with a solid CIColor using CPU pixel loops (kept for compatibility).
    private func renderSolidColor(_ color: CIColor, to pixelBuffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }

        let buffer = baseAddress.assumingMemoryBound(to: UInt8.self)

        // Convert CIColor to BGRA
        let b = UInt8(min(max(color.blue * 255, 0), 255))
        let g = UInt8(min(max(color.green * 255, 0), 255))
        let r = UInt8(min(max(color.red * 255, 0), 255))
        let a = UInt8(min(max(color.alpha * 255, 0), 255))

        for y in 0..<height {
            for x in 0..<width {
                let offset = y * bytesPerRow + x * 4
                buffer[offset] = b
                buffer[offset + 1] = g
                buffer[offset + 2] = r
                buffer[offset + 3] = a
            }
        }
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
