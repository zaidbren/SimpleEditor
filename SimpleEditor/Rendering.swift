import SwiftUI
import AVFoundation
import CoreImage
import Combine

@MainActor
class Renderer: ObservableObject {
    @Published var playerItem: AVPlayerItem?
    @Published var isLoading = false
    
    private var project: Project
    private let compositorId: String
    private let composition: AVMutableComposition
    private let videoComposition: AVMutableVideoComposition
    
    init(project: Project, videoURL: URL) {
        self.project = project
        self.compositorId = UUID().uuidString
        
        let composition = AVMutableComposition()
        let videoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        )!
        
        let asset = AVAsset(url: videoURL)
        let sourceTrack = asset.tracks(withMediaType: .video).first!
        
        try! videoTrack.insertTimeRange(
            CMTimeRange(start: .zero, duration: asset.duration),
            of: sourceTrack,
            at: .zero
        )
        
        let videoComposition = AVMutableVideoComposition()
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        videoComposition.renderSize = sourceTrack.naturalSize
        
        let instruction = CompositorInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: asset.duration)
        instruction.compositorId = compositorId
        instruction.requiredSourceTrackIDs = [NSValue(nonretainedObject: videoTrack)]
        
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
    
    func updateProject(_ project: Project) async {
        print("🔄 Renderer: Updating project (compositor ID: \(compositorId))")
        self.project = project
        await CustomVideoCompositor.updateProject(project, forId: compositorId)
        print("✅ Renderer: Project updated successfully")
    }
    
    func cleanup() async {
        await CustomVideoCompositor.removeProject(forId: compositorId)
    }
}

class CompositorInstruction: NSObject, AVVideoCompositionInstructionProtocol {
    var timeRange: CMTimeRange = .zero
    var enablePostProcessing: Bool = false
    var containsTweening: Bool = false
    var requiredSourceTrackIDs: [NSValue]?
    var passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid
    var compositorId: String = ""
}

class CustomVideoCompositor: NSObject, AVVideoCompositing {
    private let renderQueue = DispatchQueue(label: "compositor.render", qos: .userInteractive)
    
    private actor ProjectStorage {
        private var projects: [String: Project] = [:]
        
        func setProject(_ project: Project, forId id: String) {
            projects[id] = project
        }
        
        func getProject(forId id: String) -> Project? {
            return projects[id]
        }
        
        func removeProject(forId id: String) {
            projects.removeValue(forKey: id)
        }
    }
    
    private static let projectStorage = ProjectStorage()
    
    required override init() {
        super.init()
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
    }
    
    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        renderQueue.async { [weak self] in
            guard let self = self else {
                request.finish(with: self?.makeError("Compositor deallocated") ?? NSError())
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
            
            Task {
                guard let project = await CustomVideoCompositor.getProject(forId: compositorId) else {
                    request.finish(with: self.makeError("No project found"))
                    return
                }
                
                let color = project.backgroundColor
                self.renderSolidColor(color, to: outputBuffer)
                
                print("🎨 Frame at \(String(format: "%.2f", seconds))s - Color: R:\(color.red) G:\(color.green) B:\(color.blue)")
                
                request.finish(withComposedVideoFrame: outputBuffer)
            }
        }
    }
    
    func cancelAllPendingVideoCompositionRequests() {
        renderQueue.sync(flags: .barrier) {}
    }
    
    private func renderSolidColor(_ color: CIColor, to pixelBuffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
        
        let buffer = baseAddress.assumingMemoryBound(to: UInt8.self)
        
        let b = UInt8(color.blue * 255)
        let g = UInt8(color.green * 255)
        let r = UInt8(color.red * 255)
        let a = UInt8(color.alpha * 255)
        
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
    
    private func makeError(_ message: String) -> NSError {
        return NSError(
            domain: "CustomVideoCompositor",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}
