import Foundation
import CTDLib

struct TDError: Error, CustomStringConvertible {
    let code: Int
    let message: String

    /// Our own answer for requests to a client that has already reported `authorizationStateClosed`.
    static let closed = TDError(code: -2, message: "Сессия TDLib закрыта")

    var isSessionClosed: Bool { code == Self.closed.code }
    var isRateLimited: Bool { code == 429 }
    var isNotFound: Bool { code == 404 }

    /// Seconds from "Too Many Requests: retry after N".
    var retryAfter: Double? {
        guard isRateLimited, let tail = message.split(separator: " ").last else { return nil }
        return Double(tail)
    }

    var description: String { "TDLib \(code): \(message)" }
}

/// One TDLib instance on top of the shared `td_receive` loop. Requests are matched to responses through
/// `@extra`; every other message is delivered to `onUpdate` on the main queue, in the order TDLib sent it.
/// An instance ends with `authorizationStateClosed`; a new session needs a new bridge.
final class TDBridge: @unchecked Sendable {
    private let clientId = TDReceiver.shared.createClient()
    private let sync = NSLock()
    private var pending: [Int64: CheckedContinuation<TDNode, Error>] = [:]
    private var nextExtra: Int64 = 1
    private var onUpdate: (@MainActor (TDNode) -> Void)?
    private var isClosed = false
    /// Updates waiting for the main thread; they go over in batches instead of one hop each.
    private var pendingUpdates: [TDNode] = []
    private var isFlushScheduled = false

    /// Synchronous requests that need no client, such as the log settings.
    static func execute(_ request: TDNode) {
        guard let data = try? JSONSerialization.data(withJSONObject: request),
              let encoded = String(data: data, encoding: .utf8) else { return }
        _ = td_execute(encoded)
    }

    /// The same for requests that answer, such as `parseMarkdown`: TDLib runs these few on the calling thread,
    /// without a client. Its answer lives in a buffer of its own that the next call reuses, so it is copied out.
    static func answer(_ request: TDNode) -> TDNode? {
        guard let data = try? JSONSerialization.data(withJSONObject: request),
              let encoded = String(data: data, encoding: .utf8),
              let result = td_execute(encoded) else { return nil }
        let node = (try? JSONSerialization.jsonObject(with: Data(bytes: result, count: strlen(result)))) as? TDNode
        return node?.tdType == "error" ? nil : node
    }

    func start(onUpdate: @escaping @MainActor (TDNode) -> Void) {
        sync.lock()
        self.onUpdate = onUpdate
        sync.unlock()
        TDReceiver.shared.attach(self, clientId: clientId)
    }

    func request(_ request: TDNode) async throws -> TDNode {
        var payload = request
        let extra = claimExtra()
        payload["@extra"] = extra

        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let encoded = String(data: data, encoding: .utf8) else {
            throw TDError(code: -1, message: "не удалось закодировать запрос \(request["@type"] ?? "?")")
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                sync.lock()
                defer { sync.unlock() }
                guard !isClosed else {
                    continuation.resume(throwing: TDError.closed)
                    return
                }
                pending[extra] = continuation
                td_send(clientId, encoded)
            }
        } onCancel: {
            // The request is already sent, and only TDLib's answer would resume the waiter — so a caller that
            // went away has to be released here, or the continuation sits in `pending` for the whole session.
            sync.lock()
            let waiting = pending.removeValue(forKey: extra)
            sync.unlock()
            waiting?.resume(throwing: CancellationError())
        }
    }

    private func claimExtra() -> Int64 {
        sync.lock()
        defer { sync.unlock() }
        nextExtra += 1
        return nextExtra
    }

    fileprivate func route(_ payload: TDNode) {
        guard payload["@extra"] != nil else {
            deliver(payload)
            return
        }

        let extra = (payload["@extra"] as? NSNumber)?.int64Value ?? 0
        sync.lock()
        let continuation = pending.removeValue(forKey: extra)
        sync.unlock()

        guard let continuation else { return }
        if payload.tdType == "error" {
            continuation.resume(throwing: TDError(code: payload.tdInt("code"), message: payload.tdString("message")))
        } else {
            continuation.resume(returning: payload)
        }
    }

    private func deliver(_ update: TDNode) {
        if update.tdType == "updateAuthorizationState",
           update.tdNode("authorization_state")?.tdType == "authorizationStateClosed" {
            finish()
        }

        // Startup brings thousands of updates; one main-thread block per burst keeps the interface responsive
        // and lets SwiftUI redraw once for the whole burst. Order is kept: a batch is drained front to back, and
        // a request's reply is resumed after the batch that was already queued ahead of it.
        sync.lock()
        pendingUpdates.append(update)
        let handler = onUpdate
        // The flag goes up only together with the block that clears it. Raised before a handler exists, it would
        // stay up forever and no update would ever reach the interface again.
        let needsFlush = !isFlushScheduled
        if needsFlush, handler != nil { isFlushScheduled = true }
        sync.unlock()
        guard needsFlush, let handler else { return }
        DispatchQueue.main.async { [self] in
            sync.lock()
            // Swapped out, not copied: with `batch` still holding the storage, emptying the array in place
            // allocated a second buffer of the same size under the lock.
            var batch: [TDNode] = []
            swap(&batch, &pendingUpdates)
            isFlushScheduled = false
            sync.unlock()
            MainActor.assumeIsolated {
                for update in batch { handler(update) }
            }
        }
    }

    /// TDLib sends nothing after `authorizationStateClosed`, so waiting requests would never be answered.
    /// This runs before the update is delivered, so the database is already released when the app reacts.
    private func finish() {
        sync.lock()
        isClosed = true
        let waiting = Array(pending.values)
        pending.removeAll()
        sync.unlock()

        TDReceiver.shared.detach(clientId: clientId)
        for continuation in waiting {
            continuation.resume(throwing: TDError.closed)
        }
    }
}

/// `td_receive` serves every client of the process and must only be called from one thread.
private final class TDReceiver: @unchecked Sendable {
    static let shared = TDReceiver()

    private let sync = NSLock()
    private var clients: [Int32: TDBridge] = [:]
    private var isRunning = false

    func createClient() -> Int32 {
        td_create_client_id()
    }

    func attach(_ bridge: TDBridge, clientId: Int32) {
        sync.lock()
        clients[clientId] = bridge
        let needsThread = !isRunning
        isRunning = true
        sync.unlock()

        guard needsThread else { return }
        let thread = Thread { [unowned self] in receiveLoop() }
        thread.name = "ru.anemia.swiftlite.tdlib.receive"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    func detach(clientId: Int32) {
        sync.lock()
        clients[clientId] = nil
        sync.unlock()
    }

    private func receiveLoop() {
        while true {
            // A bare thread has no run loop to drain its autorelease pool, and this loop never returns: without
            // a pool of its own every parsed update left about 0.8 KB behind for good — 250 MB after 300 000
            // updates, which a busy account sees in a day.
            autoreleasepool {
                guard let result = td_receive(1.0), let payload = Self.json(from: result) else { return }
                let clientId = (payload["@client_id"] as? NSNumber)?.int32Value ?? 0
                sync.lock()
                let bridge = clients[clientId]
                sync.unlock()
                bridge?.route(payload)
            }
        }
    }

    /// `td_receive` invalidates its buffer on the next call, so it is copied once, straight into Data
    /// (not through a String, which would be a second copy and a UTF-8 validation pass).
    private static func json(from buffer: UnsafePointer<CChar>) -> TDNode? {
        let data = Data(bytes: buffer, count: strlen(buffer))
        return (try? JSONSerialization.jsonObject(with: data)) as? TDNode
    }
}
