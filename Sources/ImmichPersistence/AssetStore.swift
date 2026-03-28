import Foundation
import ImmichCore

public actor AssetStore {
  private var cachedAssets: [UUID: URL] = [:]

  public init() {}

  public func saveUploadedAsset(_ item: UploadItem) {
    cachedAssets[item.id] = item.fileURL
  }

  public func assetURL(id: UUID) -> URL? {
    cachedAssets[id]
  }

  public func allAssetURLs() -> [URL] {
    cachedAssets.values.sorted { $0.absoluteString < $1.absoluteString }
  }
}
