#if canImport(Foundation)
import Foundation
import CoreFoundation
import ImmichAPI
import ImmichCore

@MainActor
protocol ImmichWebSocketDelegate: AnyObject {
  func webSocketDidConnect()
  func webSocketDidDisconnect()
  func webSocketDidReceiveAssetUpload(assetJSON: [String: Any])
  func webSocketDidReceiveAssetUpdate(assetJSON: [String: Any])
  func webSocketDidReceiveAssetDelete(assetID: String)
  func webSocketDidReceiveAssetTrash(assetIDs: [String])
  func webSocketDidReceiveAssetRestore(assetIDs: [String])
  func webSocketDidReceiveReleaseNotification(releaseVersion: String, serverVersion: String?)
}

@MainActor
protocol ImmichWebSocketServicing: AnyObject {
  var delegate: (any ImmichWebSocketDelegate)? { get set }

  func connect(server: ImmichServer, userSession: UserSession)
  func disconnect()
}
final class ImmichWebSocketService: NSObject, ImmichWebSocketServicing, @unchecked Sendable {
  private var webSocketTask: URLSessionWebSocketTask?
  private var session: URLSession?
  private var connectionRequest: URLRequest?
  private var isConnected = false
  private var reconnectTask: Task<Void, Never>?
  private var reconnectAttempt = 0
  private let maxReconnectAttempts = 10
  private var intentionalDisconnect = false

  weak var delegate: (any ImmichWebSocketDelegate)?

  @MainActor
  func connect(server: ImmichServer, userSession: UserSession) {
    intentionalDisconnect = false
    reconnectAttempt = 0

    let baseURL = server.baseURL
    guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
      immichLog("[WebSocket] Invalid server URL")
      return
    }

    components.scheme = baseURL.scheme == "https" ? "wss" : "ws"
    let normalizedBasePath = baseURL.path.hasSuffix("/") ? String(baseURL.path.dropLast()) : baseURL.path
    components.path = normalizedBasePath + "/socket.io/"
    components.queryItems = [
      URLQueryItem(name: "EIO", value: "4"),
      URLQueryItem(name: "transport", value: "websocket"),
    ]

    guard let url = components.url else {
      immichLog("[WebSocket] Failed to construct WebSocket URL")
      return
    }

    var request = URLRequest(url: url)
    request.addValue(userSession.authHeaderValue, forHTTPHeaderField: userSession.authHeaderField)
    connectionRequest = request

    let config = URLSessionConfiguration.default
    session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    webSocketTask = session?.webSocketTask(with: request)
    webSocketTask?.resume()

    receiveMessage()
    immichLog("[WebSocket] Connecting to \(url.absoluteString)")
  }

  @MainActor
  func disconnect() {
    intentionalDisconnect = true
    reconnectTask?.cancel()
    reconnectTask = nil
    webSocketTask?.cancel(with: .goingAway, reason: nil)
    webSocketTask = nil
    connectionRequest = nil
    session?.invalidateAndCancel()
    session = nil
    isConnected = false
    delegate?.webSocketDidDisconnect()
  }

  @MainActor
  private func receiveMessage() {
    webSocketTask?.receive { [weak self] result in
      guard let self else { return }
      Task { @MainActor in
        switch result {
        case .success(let message):
          switch message {
          case .string(let text):
            self.handleEngineIOMessage(text)
          case .data:
            break
          @unknown default:
            break
          }
          self.receiveMessage()
        case .failure(let error):
          immichLog("[WebSocket] Receive error: \(error.localizedDescription)")
          self.handleDisconnection()
        }
      }
    }
  }

  @MainActor
  private func handleEngineIOMessage(_ raw: String) {
    guard let firstChar = raw.first else { return }

    switch firstChar {
    case "0":
      handleEngineIOOpen()
    case "2":
      if let response = Self.engineIOHeartbeatResponse(toServerPacket: raw) {
        sendRaw(response)
      }
    case "3":
      break
    case "4":
      handleSocketIOMessage(String(raw.dropFirst()))
    default:
      break
    }
  }

  @MainActor
  private func handleEngineIOOpen() {
    sendRaw("40")
  }

  @MainActor
  private func handleSocketIOMessage(_ payload: String) {
    guard let firstChar = payload.first else { return }

    switch firstChar {
    case "0":
      isConnected = true
      immichLog("[WebSocket] Socket.IO connected")
      reconnectAttempt = 0
      delegate?.webSocketDidConnect()
    case "2":
      handleSocketIOEvent(String(payload.dropFirst()))
    default:
      break
    }
  }

  @MainActor
  private func handleSocketIOEvent(_ jsonPayload: String) {
    guard let data = jsonPayload.data(using: .utf8),
          let parsed = try? JSONSerialization.jsonObject(with: data) as? [Any],
          let eventName = parsed.first as? String else { return }

    let eventData = parsed.count > 1 ? parsed[1] : nil

    switch eventName {
    case "on_upload_success":
      if let assetJSON = eventData as? [String: Any] {
        delegate?.webSocketDidReceiveAssetUpload(assetJSON: assetJSON)
      }
    case "on_asset_update":
      if let assetJSON = eventData as? [String: Any] {
        delegate?.webSocketDidReceiveAssetUpdate(assetJSON: assetJSON)
      }
    case "on_asset_delete":
      if let assetID = eventData as? String {
        delegate?.webSocketDidReceiveAssetDelete(assetID: assetID)
      }
    case "on_asset_trash":
      if let ids = eventData as? [String] {
        delegate?.webSocketDidReceiveAssetTrash(assetIDs: ids)
      }
    case "on_asset_restore":
      if let ids = eventData as? [String] {
        delegate?.webSocketDidReceiveAssetRestore(assetIDs: ids)
      }
    case "on_session_delete":
      immichLog("[WebSocket] Session deleted by server")
    case "on_new_release":
      if let payload = eventData as? [String: Any],
         let versions = Self.releaseVersions(from: payload) {
        delegate?.webSocketDidReceiveReleaseNotification(
          releaseVersion: versions.releaseVersion,
          serverVersion: versions.serverVersion
        )
      }
    default:
      break
    }
  }

  static func engineIOHeartbeatResponse(toServerPacket packet: String) -> String? {
    guard packet.first == "2" else { return nil }
    return "3" + String(packet.dropFirst())
  }

  static func releaseVersions(
    from payload: [String: Any]
  ) -> (releaseVersion: String, serverVersion: String?)? {
    guard let releaseVersion = semanticVersion(from: payload["releaseVersion"]) else {
      return nil
    }
    return (
      releaseVersion: releaseVersion,
      serverVersion: semanticVersion(from: payload["serverVersion"])
    )
  }

  private static func semanticVersion(from value: Any?) -> String? {
    guard let version = value as? [String: Any],
          let major = versionComponent(version["major"]),
          let minor = versionComponent(version["minor"]),
          let patch = versionComponent(version["patch"]) else {
      return nil
    }

    var result = "\(major).\(minor).\(patch)"
    if let prereleaseValue = version["prerelease"], !(prereleaseValue is NSNull) {
      guard let prerelease = prereleaseValue as? String else { return nil }
      if !prerelease.isEmpty {
        guard isValidPrerelease(prerelease) else { return nil }
        result += "-\(prerelease)"
      }
    }
    return result
  }

  private static func versionComponent(_ value: Any?) -> Int? {
    guard let number = value as? NSNumber,
          CFGetTypeID(number) != CFBooleanGetTypeID(),
          let component = Int(number.stringValue),
          component >= 0 else {
      return nil
    }
    return component
  }

  private static func isValidPrerelease(_ prerelease: String) -> Bool {
    let identifiers = prerelease.split(separator: ".", omittingEmptySubsequences: false)
    guard !identifiers.isEmpty else { return false }
    return identifiers.allSatisfy { identifier in
      guard !identifier.isEmpty,
            identifier.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else {
        return false
      }
      if identifier.allSatisfy(\.isNumber), identifier.count > 1, identifier.first == "0" {
        return false
      }
      return true
    }
  }

  private func sendRaw(_ message: String) {
    webSocketTask?.send(.string(message)) { error in
      if let error {
        immichLog("[WebSocket] Send error: \(error.localizedDescription)")
      }
    }
  }

  @MainActor
  private func handleDisconnection() {
    guard !intentionalDisconnect else {
      // disconnect() already notified the delegate and cleaned up state.
      return
    }
    isConnected = false

    delegate?.webSocketDidDisconnect()

    guard reconnectAttempt < maxReconnectAttempts else {
      return
    }

    reconnectTask?.cancel()
    reconnectTask = Task { @MainActor [weak self] in
      guard let self else { return }
      let delay = min(pow(2.0, Double(self.reconnectAttempt)), 30.0)
      self.reconnectAttempt += 1
      immichLog("[WebSocket] Reconnecting in \(delay)s (attempt \(self.reconnectAttempt))")
      try? await Task.sleep(for: .seconds(delay))
      guard !Task.isCancelled, let request = self.connectionRequest else { return }

      self.webSocketTask?.cancel(with: .goingAway, reason: nil)
      self.webSocketTask = self.session?.webSocketTask(with: request)
      self.webSocketTask?.resume()
      self.receiveMessage()
    }
  }
}

extension ImmichWebSocketService: URLSessionWebSocketDelegate {
  nonisolated func urlSession(
    _ session: URLSession,
    webSocketTask: URLSessionWebSocketTask,
    didOpenWithProtocol protocol: String?
  ) {
    immichLog("[WebSocket] Transport connected")
  }

  nonisolated func urlSession(
    _ session: URLSession,
    webSocketTask: URLSessionWebSocketTask,
    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
    reason: Data?
  ) {
    immichLog("[WebSocket] Transport closed: \(closeCode)")
    Task { @MainActor in
      self.handleDisconnection()
    }
  }
}
#endif
