import Foundation

public struct ImmichServer: Hashable, Sendable {
  public let baseURL: URL

  public init(baseURL: URL) {
    self.baseURL = baseURL
  }
}

public struct ServerInfo: Decodable, Sendable {
  public let version: String
  public let repository: String?

  public init(version: String, repository: String? = nil) {
    self.version = version
    self.repository = repository
  }
}

public struct UploadItem: Identifiable, Equatable, Sendable {
  public let id: UUID
  public let fileURL: URL

  public init(id: UUID = UUID(), fileURL: URL) {
    self.id = id
    self.fileURL = fileURL
  }
}

public enum UploadState: Equatable, Sendable {
  case queued
  case uploading(progress: Double)
  case done
  case failed(reason: String)
}
