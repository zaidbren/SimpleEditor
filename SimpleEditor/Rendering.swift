// Renderer.swift
import AVFoundation
import CoreImage
import Combine
import CoreImage.CIFilterBuiltins

@MainActor
class Renderer: ObservableObject {
    @Published var composition: AVComposition?
    @Published var videoComposition: AVVideoComposition?
    @Published var playerItem: AVPlayerItem?
    @Published var asset: AVAsset?
    @Published var error: Error?
    @Published var isLoading = false
    
    private var screenTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid
    
    private var project: Project
    private let compositorId: String
    
    init(project: Project) {
        self.project = project
        self.compositorId = UUID().uuidString
    }
    
    func updateProject(_ project: Project) async {
        self.project = project
    }
    
    // MARK: - Composition Building
    
    func buildComposition() async {
        isLoading = true
        error = nil
        
        do {
            let fileName = "recording-display-0"
            let fileExtension = "mp4"
            
            guard let videoURL = Bundle.main.url(forResource: fileName, withExtension: fileExtension) else {
                print("Warning: Video '\(fileName).\(fileExtension)' not found in bundle")
                throw VideoCompositionError.videoFileNotFound
            }
            
            print("Found video in bundle: \(videoURL.path)")
            
            // Create composition
            let composition = AVMutableComposition()
            let videoTrack = composition.addMutableTrack(
                withMediaType: .video,
                preferredTrackID: kCMPersistentTrackID_Invalid
            )
            
            guard let videoTrack = videoTrack else {
                throw VideoCompositionError.trackCreationFailed
            }
            
            let asset = AVURLAsset(url: videoURL)
            
            print("Source nominal frameRate:", asset.tracks.first?.nominalFrameRate ?? -1)

            
            Task {
                do {
                    let screenTracks = try await asset.loadTracks(withMediaType: .video)
                    guard let screenVideoTrack = screenTracks.first else {
                        throw VideoCompositionError.trackCreationFailed
                    }
                    
                    await MainActor.run {
                        self.asset = asset
                        self.createComposition(
                            with: asset,
                            screenVideoTrack: screenVideoTrack,
                        )
                    }
                } catch {
                    print("Error loading video asset: \(error)")
                    await MainActor.run {
                        self.isLoading = false
                    }
                }
            }
            
        } catch {
            self.error = error
            self.isLoading = false
            print("Error building composition: \(error.localizedDescription)")
        }
    }
    
    private func createComposition(
        with screenAsset: AVAsset,
        screenVideoTrack: AVAssetTrack,
    ) {
        // Create mutable composition
        let composition = AVMutableComposition()
        
        // Add screen video track to composition
        guard let compositionScreenTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            print("Failed to create composition screen video track")
            isLoading = false
            return
        }
        
        Task {
            do {
                let screenDuration = try await screenAsset.load(.duration)
                let fullRange = CMTimeRange(start: .zero, duration: screenDuration)
                
                // Insert screen video
                try compositionScreenTrack.insertTimeRange(
                    fullRange,
                    of: screenVideoTrack,
                    at: .zero
                )
                
                self.screenTrackID = compositionScreenTrack.trackID
                
                await MainActor.run {
                    self.composition = composition
                    self.createVideoComposition(
                        with: composition,
                        screenTrack: compositionScreenTrack
                    )
                }
            } catch {
                print("Error creating composition: \(error)")
                await MainActor.run {
                    self.isLoading = false
                }
            }
        }
    }
    
    private func createVideoComposition(
        with composition: AVMutableComposition,
        screenTrack: AVMutableCompositionTrack
    ) {
        // Create video composition
        let videoComposition = AVMutableVideoComposition()
        
        // Store document reference for compositor
        
        Task {
            do {
                let duration = try await composition.load(.duration)
                let naturalSize = try await screenTrack.load(.naturalSize)
                let preferredTransform = try await screenTrack.load(.preferredTransform)
                
                await MainActor.run {
                    videoComposition.frameDuration = CMTime(value: 1, timescale: 60) // 60 FPS
                    videoComposition.renderSize = naturalSize
                    
                    // Create instruction for the entire duration
                    //let instruction = AVMutableVideoCompositionInstruction()
                    //instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
                    
                    let instruction = CompositorInstruction()
                    instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
                    instruction.compositorId = compositorId
                    
                    // Create layer instructions
                    var layerInstructions: [AVMutableVideoCompositionLayerInstruction] = []
                    
                    
                    // Screen layer instruction
                    let screenLayerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: screenTrack)
                    screenLayerInstruction.setTransform(preferredTransform, at: .zero)
                    layerInstructions.append(screenLayerInstruction)
                    
                    instruction.layerInstructions = layerInstructions
                    videoComposition.instructions = [instruction]
                    
                    // Assign custom compositor class with track IDs
                    videoComposition.customVideoCompositorClass = CustomVideoCompositor.self
                    
                    self.videoComposition = videoComposition
                    
                    let playerItem = AVPlayerItem(asset: composition)
                    playerItem.videoComposition = videoComposition
                    self.playerItem = playerItem
                    
                    self.isLoading = false

                    
                    print("Video composition created successfully")
                    print("Screen track ID: \(self.screenTrackID)")
                }
            } catch {
                print("Error creating video composition: \(error)")
                await MainActor.run {
                    self.isLoading = false
                }
            }
        }
    }
    
    func exportVideo(to outputURL: URL) async throws {
        guard let composition = composition,
              let videoComposition = videoComposition else {
            throw VideoCompositionError.noValidVideos
        }
        
        
        try? FileManager.default.removeItem(at: outputURL)
        guard let exportSession = AVAssetExportSession(
            asset: composition,
            /**
             •    With AVAssetExportPresetHighestQuality, the system typically picks an
             H.264 profile/level that is broadly compatible. Those internal preset settings
             often clamp the frame rate to 30 fps for high-res outputs when re-encoding.
             
             •    With AVAssetExportPresetHEVCHighestQuality, the encoder is HEVC,
             whose preset profiles on Apple hardware allow 60 fps at the same resolution,
             so your videoComposition.frameDuration = 1/60 is honored
             */
            presetName: AVAssetExportPresetHEVCHighestQuality
        ) else {
            throw VideoCompositionError.trackCreationFailed
        }
        
        exportSession.outputFileType = .mp4
        exportSession.videoComposition = videoComposition
        try await exportSession.export(to: outputURL, as: .mp4)
    }
    
    func cleanup() async {
        composition = nil
        videoComposition = nil
        playerItem = nil
        error = nil
    }
    
    func reset() async {
        await cleanup()
    }
}

// MARK: - Custom Instruction

class CompositorInstruction: NSObject, AVVideoCompositionInstructionProtocol {
    var timeRange: CMTimeRange = .zero
    var enablePostProcessing: Bool = false
    var containsTweening: Bool = true
    var requiredSourceTrackIDs: [NSValue]?
    var passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid
    var layerInstructions: [AVVideoCompositionLayerInstruction] = []
    var compositorId: String = ""
}

// MARK: - Custom Video Compositor

class CustomVideoCompositor: NSObject, AVVideoCompositing {
    
    // MARK: - AVVideoCompositing Protocol
    
    var sourcePixelBufferAttributes: [String : Any]? = [
        kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
    ]
    
    var requiredPixelBufferAttributesForRenderContext: [String : Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
    ]
    
    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {
        // Handle render context changes
    }
    
    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        
        let trackIDs = request.sourceTrackIDs.map { $0.int32Value }
        
        let videoComposition = request.renderContext.videoComposition
        let frameDuration = videoComposition.frameDuration
        let fps = Double(frameDuration.timescale) / Double(frameDuration.value)

        let compositionTime = request.compositionTime
        let seconds = CMTimeGetSeconds(compositionTime)
        let frameInMilliseconds = seconds * 1000
        let frameNumber = Int(round(seconds * fps))

        print("Frame #\(frameNumber) at \(frameInMilliseconds) ms (fps: \(fps))")
        
        let paddingRatio = 20.0

        
        // Assume first track is screen, second is background (if exists)
        var screenBuffer: CVPixelBuffer?
        screenBuffer = request.sourceFrame(byTrackID: CMPersistentTrackID(trackIDs[0]))

        guard let sourceBuffer = screenBuffer else {
            request.finish(with: NSError(domain: "OutputCompositor", code: -1, userInfo: nil))
            return
        }
        
        guard let outputBuffer = request.renderContext.newPixelBuffer() else {
            request.finish(with: NSError(domain: "OutputCompositor", code: -2, userInfo: nil))
            return
        }
        
        // Copy source buffer to output buffer
        CVPixelBufferLockBaseAddress(sourceBuffer, .readOnly)
        CVPixelBufferLockBaseAddress(outputBuffer, [])
        
        let sourceBaseAddress = CVPixelBufferGetBaseAddress(sourceBuffer)
        let destBaseAddress = CVPixelBufferGetBaseAddress(outputBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(sourceBuffer)
        let height = CVPixelBufferGetHeight(sourceBuffer)
        
        memcpy(destBaseAddress, sourceBaseAddress, bytesPerRow * height)
        
        CVPixelBufferUnlockBaseAddress(outputBuffer, [])
        CVPixelBufferUnlockBaseAddress(sourceBuffer, .readOnly)
        
        request.finish(withComposedVideoFrame: outputBuffer)
    }

    func cancelAllPendingVideoCompositionRequests() {
    }
}

// MARK: - Errors

enum VideoCompositionError: LocalizedError {
    case videoFileNotFound
    case noValidVideos
    case trackCreationFailed
    case invalidVideoTrack
    case invalidDuration
    case noAssetManager
    case timeout
    
    var errorDescription: String? {
        switch self {
        case .videoFileNotFound:
            return "Video file 'recording-display-0.mp4' not found"
        case .noValidVideos:
            return "No valid video files could be processed"
        case .trackCreationFailed:
            return "Failed to create video track in composition"
        case .invalidVideoTrack:
            return "Invalid video track in source file"
        case .invalidDuration:
            return "Invalid video duration"
        case .noAssetManager:
            return "No asset manager available"
        case .timeout:
            return "Operation timed out"
        }
    }
}
