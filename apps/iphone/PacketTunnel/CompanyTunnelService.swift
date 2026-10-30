import Foundation
#if canImport(Libbox)
import Libbox
#endif

/// Owns only the aTrust transport. It never edits rules outside Rust.
final class CompanyTunnelService: @unchecked Sendable {
    private let queue = DispatchQueue(label: "split-vpn.company.transport", qos: .utility)
    private let store = AppGroupStore.shared
    private let underlay = CompanyUnderlay()
    private let reload: @Sendable () -> Void
    private var buffer = CompanyTransferBuffer()
    private var timer: DispatchSourceTimer?
    private var state: [String: Any] = ["phase": "idle", "message": "尚未建立接入"]
    private var record: [String: Any] = [:]
    private var operation = UUID()
    private var wanted = false
    private var verifying = false
    private var attemptDeadline: TimeInterval = 0
    private var expectedRevision: String?
    private var lastTransfer: String?
    private let transportLock = NSLock()
    private var transport: [String: Any]?
    #if canImport(Libbox)
    private var attempt: CompanymobileTunnelAttempt?
    #endif
    init(reload: @escaping @Sendable () -> Void) { self.reload = reload }
    func handle(_ message: [String: Any], reply: @escaping @Sendable ([String: Any]) -> Void) {
        queue.async { [self] in
            do {
                let command = message["op"] as? String ?? ""
                let id = message["id"] as? String ?? ""
                let now = ProcessInfo.processInfo.systemUptime
                switch command {
                case "company.begin":
                    try buffer.begin(id: id, parts: message["parts"] as? Int ?? 0, now: now)
                    queue.asyncAfter(deadline: .now() + 31) { [weak self] in if self?.buffer.id == id { self?.buffer.clear() } }
                case "company.chunk": try buffer.append(id: id, index: message["index"] as? Int ?? -1, base64: message["chunk"] as? String ?? "", now: now)
                case "company.commit":
                    let transfer = try buffer.finish(id: id, now: now)
                    record = try MobileCoreBridge.object(root: store.url("core"), channel: "company:mobile:get")
                    let value = try JSONSerialization.jsonObject(with: Data(transfer.utf8)) as? [String: Any] ?? [:]
                    guard ["origin", "username", "fingerprint"].allSatisfy({ (record[$0] as? String) == (value[$0] as? String) }) else { throw failure("接入会话与当前账号、证书或授权不匹配") }
                    wanted = true; start(transfer)
                case "company.status": break
                case "company.cancel": stopTransport(); state = ["phase": "cancelled", "message": "已取消；已启用的授权资源继续保持阻断"]
                case "company.disconnect": stopTransport(); state = ["phase": "idle", "message": "接入已关闭"]; reload()
                case "company.verify":
                    guard !verifying else { throw failure("已有业务验证正在进行") }
                    #if canImport(Libbox)
                    guard let live = attempt, state["phase"] as? String == "connected" else { throw failure("请先连接接入") }
                    let target = message["target"] as? String ?? ""
                    let token = operation; verifying = true
                    DispatchQueue.global(qos: .utility).async { [weak self] in
                        let result = Result { try CompanySDK.verify(live, target: target) }
                        self?.queue.async { [weak self] in
                            guard let self, token == self.operation else { return }
                            self.verifying = false
                            switch result {
                            case .success(let text): self.state["verification"] = (try? JSONSerialization.jsonObject(with: Data(text.utf8))); self.state["message"] = "指定业务已通过接入隧道验证"
                            case .failure: self.state["message"] = "指定业务未通过接入隧道验证，请检查业务地址和授权"
                            }
                        }
                    }
                    #else
                    throw failure("接入内核未编入当前构建")
                    #endif
                default: throw failure("接入命令无效")
                }
                var response = state; response["ok"] = true; response["verifying"] = verifying; reply(response)
            } catch { reply(["ok": false, "error": Redaction.message(error.localizedDescription)]) }
        }
    }
    private func start(_ transfer: String) {
        transportLock.lock(); transport = nil; transportLock.unlock()
        operation = UUID(); expectedRevision = nil; lastTransfer = transfer; attemptDeadline = ProcessInfo.processInfo.systemUptime + 45
        #if canImport(Libbox)
        attempt?.close(); attempt = nil
        if !underlay.interfaceName.isEmpty { attempt = CompanymobileStartTunnel(transfer, underlay.interfaceName) }
        #endif
        state = ["phase": underlay.interfaceName.isEmpty ? "waiting-network" : "connecting", "message": underlay.interfaceName.isEmpty ? "等待物理网络恢复" : "正在建立 aTrust TCP 接入"]
        timer?.cancel()
        let poll = DispatchSource.makeTimerSource(queue: queue)
        poll.schedule(deadline: .now(), repeating: .seconds(1), leeway: .milliseconds(100))
        poll.setEventHandler { [weak self] in self?.checkAttempt() }; timer = poll; poll.resume()
    }
    private func checkAttempt() {
        #if canImport(Libbox)
        guard wanted else { return }
        if state["phase"] as? String != "connected", ProcessInfo.processInfo.systemUptime > attemptDeadline { attempt?.close(); timer?.cancel(); timer = nil; state = ["phase": "error", "message": "接入建立或配置应用超时，授权保护保持阻断"]; return }
        if attempt == nil, !underlay.interfaceName.isEmpty, let lastTransfer { start(lastTransfer); return }
        guard let attempt, let value = try? JSONSerialization.jsonObject(with: Data(attempt.status().utf8)) as? [String: Any] else { return }
        switch value["phase"] as? String {
        case "ready":
            if ["connected", "applying"].contains(state["phase"] as? String ?? ""), expectedRevision != nil { return }
            do {
                var descriptor = record; descriptor["port"] = value["port"]
                transportLock.lock(); transport = descriptor; transportLock.unlock()
                try prepareConfiguration()
                state = ["phase": "applying", "message": "接入已就绪，正在应用授权资源分流"]
                reload()
            } catch { state = ["phase": "applying", "message": "等待最新配置完成生成；授权资源保持阻断"] }
        case "failed", "cancelled": timer?.cancel(); timer = nil; transportLock.lock(); transport = nil; transportLock.unlock(); reload(); state = ["phase": "error", "message": value["error"] as? String ?? "接入中断，授权资源保持阻断"]
        default: break
        }
        #endif
    }
    /// Called on the core queue before every reload, including personal node edits.
    func prepareConfiguration() throws {
        transportLock.lock(); let descriptor = transport; transportLock.unlock()
        guard let descriptor else { return }
        let revision: String? = try MobileCoreBridge.withTransaction(root: store.url("core")) {
            guard var generated = store.readGeneratedConfig(), let raw = generated.singBoxJSON, let revision = generated.runtimeRevision else { throw failure("缺少待应用的隧道配置") }
            let current = try MobileCoreBridge.object(root: store.url("core"), channel: "company:mobile:get")
            if current["enabled"] as? Bool != true { return revision }
            let result = try MobileCoreBridge.object(root: store.url("core"), channel: "company:mobile:bind", payload: ["expectedRevision": revision, "config": raw, "transport": descriptor])
            generated.singBoxJSON = result["config"] as? String; generated.runtimeRevision = result["runtimeRevision"] as? String
            try store.saveGeneratedConfig(generated); return generated.runtimeRevision
        }
        queue.async { [self] in
            if expectedRevision != revision { attemptDeadline = ProcessInfo.processInfo.systemUptime + 45; state = ["phase": "applying", "message": "正在确认最新资源接管配置"] }
            expectedRevision = revision
        }
    }
    func applied(_ revision: String?) {
        queue.async { [self] in
            if wanted, let expectedRevision, expectedRevision == revision {
                let current = try? MobileCoreBridge.object(root: store.url("core"), channel: "company:mobile:get")
                state = ["phase": "connected", "message": current?["enabled"] as? Bool == true ? "授权 TCP 资源已接管；业务地址需单独验证" : "接入已连接，其他应用的资源尚未接管"]
            }
        }
    }
    func networkChanged() {
        queue.async { [self] in
            guard wanted else { return }
            #if canImport(Libbox)
            let transfer = (try? attempt.map { try CompanySDK.export($0) }) ?? lastTransfer
            if let transfer { start(transfer) } else { state = ["phase": "error", "message": "接入会话已失效，请重新登录"] }
            #endif
        }
    }
    func stop() { queue.async { [self] in stopTransport() } }
    private func stopTransport() {
        transportLock.lock(); transport = nil; transportLock.unlock()
        wanted = false; operation = UUID(); timer?.cancel(); timer = nil; buffer.clear(); verifying = false; lastTransfer = nil; expectedRevision = nil
        #if canImport(Libbox)
        let old = attempt; attempt = nil; if let old { DispatchQueue.global(qos: .utility).async { old.close() } }
        #endif
    }
    private func failure(_ message: String) -> NSError { NSError(domain: "CompanyTunnel", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
