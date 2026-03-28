import Foundation
import ImmichAPI
import ImmichCore

public actor UploadQueue {
  private(set) var states: [UUID: UploadState] = [:]

  public init() {}

  public func enqueue(_ item: UploadItem) {
    states[item.id] = .queued
  }

  public func markUploading(_ item: UploadItem, progress: Double) {
    states[item.id] = .uploading(progress: progress)
  }

  public func markDone(_ item: UploadItem) {
    states[item.id] = .done
  }

  public func markFailed(_ item: UploadItem, reason: String) {
    states[item.id] = .failed(reason: reason)
  }

  public func state(for itemID: UUID) -> UploadState? {
    states[itemID]
  }
}
