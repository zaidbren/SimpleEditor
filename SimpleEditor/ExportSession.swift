import Foundation

struct ExportSetting: Identifiable, Codable, Sendable, Equatable {

    var id: UUID = UUID()
    
    var resolution: ExportResolution = .res4K
    var format: ExportFormat = .mp4
    var frameRate: FrameRate = .fps60
    var quality: Quality = .studio

    init(
        resolution: ExportResolution = .res4K,
        format: ExportFormat = .mp4,
        frameRate: FrameRate = .fps60,
        quality: Quality = .studio
    ) {
        self.resolution = resolution
        self.format = format
        self.frameRate = frameRate
        self.quality = quality
    }
}

enum ExportResolution: String, Codable, Sendable, Equatable, CaseIterable {
    case res4K = "4K"
    case res2K = "2K"
    case res1080p = "1080p"
    case res720p = "720p"
}

enum ExportFormat: String, CaseIterable, Codable, Sendable, Equatable {
    case mp4 = "MP4"
    case gif = "GIF"
}

enum FrameRate: String, CaseIterable, Codable, Sendable, Equatable {
    case fps30 = "30"
    case fps45 = "45"
    case fps60 = "60"
    
    var value: Int {
        Int(rawValue) ?? 60
    }
}

enum Quality: String, CaseIterable, Codable, Sendable, Equatable {
    case studio = "Studio"
    case socialMedia = "Social Media"
    case web = "Web"
    
}
