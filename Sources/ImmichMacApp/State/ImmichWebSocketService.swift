#if canImport(Foundation)
import Foundation
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
}

final class ImmichWebSocketService: NSObject, @unchecked Sendable {
  private var webSocketTask: URLSessionWebSocketTask?
  private var session: URLSession?
  private var connectionRequest: URLRequest?
  private var pingTimer: Timer?
  private var pingInterval: TimeInterval = 25
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
    stopPingTimer()
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
      handleEngineIOOpen(raw)
    case "2":
      sendRaw("3")
    case "3":
      break
    case "4":
      handleSocketIOMessage(String(raw.dropFirst()))
    default:
      break
    }
  }

  @MainActor
  private func handleEngineIOOpen(_ raw: String) {
    let jsonString = String(raw.dropFirst())
    if let data = jsonString.data(using: .utf8),
       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
      if let interval = json["pingInterval"] as? TimeInterval {
        pingInterval = interval / 1000.0
      }
    }

    sendRaw("40")
    startPingTimer()
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
    default:
      break
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
  private func startPingTimer() {
    stopPingTimer()
    pingTimer = Timer.scheduledTimer(withTimeInterval: pingInterval, repeats: true) { [weak self] _ in
      self?.sendRaw("2")
    }
  }

  @MainActor
  private func stopPingTimer() {
    pingTimer?.invalidate()
    pingTimer = nil
  }

  @MainActor
  private func handleDisconnection() {
    guard !intentionalDisconnect else {
      // disconnect() already notified the delegate and cleaned up state.
      return
    }
    isConnected = false
    stopPingTimer()
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
