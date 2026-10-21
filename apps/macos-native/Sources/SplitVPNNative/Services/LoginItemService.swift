import Foundation
import ServiceManagement

enum LoginItemState: Equatable {
    case disabled, enabled, requiresApproval, needsRepair
    var requested: Bool { self == .enabled || self == .requiresApproval }
    var title: String {
        switch self {
        case .enabled: return "登录时启动"
        case .requiresApproval: return "等待系统批准"
        case .needsRepair: return "启动配置需更新"
        case .disabled: return "手动启动"
        }
    }
    var detail: String {
        switch self {
        case .enabled: return "已加入系统登录项；下次登录 Mac 时启动轻舟，并自动连接上次选择的节点。"
        case .requiresApproval: return "请在系统设置的“登录项”中允许轻舟启动。"
        case .needsRepair: return "旧启动配置还未注册为系统登录项，请重新开启这个开关。"
        case .disabled: return "打开轻舟后会自动连接上次选择的节点。"
        }
    }
}

@MainActor
protocol LoginItemService {
    func state() -> LoginItemState
    func setEnabled(_ enabled: Bool) throws -> LoginItemState
    func repairLegacyRegistration() throws -> LoginItemState
    func openSystemSettings()
}
extension LoginItemService {
    func repairLegacyRegistration() throws -> LoginItemState { state() }
}

@MainActor
final class NativeLoginItemService: LoginItemService {
    static let label = "dev.split-vpn.desktop.swiftui.v032.login"
    private let bundleID: String
    private let appURL: URL
    private let agentURL: URL
    private let installationRoots: [URL]
    private let modernState: () -> LoginItemState
    private let register: () throws -> Void
    private let unregister: () throws -> Void
    private let legacyState: (URL) -> LoginItemState
    private let showSettings: () -> Void
    private let files = FileManager.default

    init(appURL: URL = Bundle.main.bundleURL,
         bundleID: String = Bundle.main.bundleIdentifier ?? "dev.split-vpn.desktop.swiftui.v032",
         agentDirectory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents"),
         installationRoots: [URL] = [URL(fileURLWithPath: "/Applications"), FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")],
         modernState: @escaping () -> LoginItemState = { NativeLoginItemService.map(SMAppService.mainApp.status) },
         register: @escaping () throws -> Void = { try SMAppService.mainApp.register() },
         unregister: @escaping () throws -> Void = { try SMAppService.mainApp.unregister() },
         legacyState: @escaping (URL) -> LoginItemState = { NativeLoginItemService.map(SMAppService.statusForLegacyPlist(at: $0)) },
         showSettings: @escaping () -> Void = { SMAppService.openSystemSettingsLoginItems() }) {
        self.appURL = appURL.standardizedFileURL; self.bundleID = bundleID
        agentURL = agentDirectory.appendingPathComponent(Self.label + ".plist")
        self.installationRoots = installationRoots
        self.modernState = modernState; self.register = register; self.unregister = unregister
        self.legacyState = legacyState; self.showSettings = showSettings
    }
    nonisolated private static func map(_ status: SMAppService.Status) -> LoginItemState {
        switch status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        default: return .disabled
        }
    }
    func state() -> LoginItemState {
        let modern = modernState()
        if modern == .enabled || modern == .requiresApproval { return modern }
        guard exists else { return .disabled }
        guard let record = try? ownedAgent(), let arguments = record["ProgramArguments"] as? [String],
              arguments.last == appURL.path else { return .needsRepair }
        return legacyState(agentURL) == .requiresApproval ? .requiresApproval : .needsRepair
    }
    func repairLegacyRegistration() throws -> LoginItemState {
        // The former on-switch wrote this exact owned file. Preserve that
        // opt-in on upgrade, without creating a login item for opted-out users.
        guard exists, let record = try? ownedAgent(),
              let arguments = record["ProgramArguments"] as? [String],
              arguments.last == appURL.path else { return state() }
        if legacyState(agentURL) == .requiresApproval { return state() }
        return try setEnabled(true)
    }
    func setEnabled(_ enabled: Bool) throws -> LoginItemState {
        do {
            // Validate before changing system registration; foreign files must
            // not produce a partial registration or be removed by migration.
            if exists { _ = try ownedAgent() }
            let modern = modernState()
            if !enabled {
                // The shared legacy preference is not proof of registration.
                // An absent native item is already disabled; do not unregister it.
                if modern == .enabled || modern == .requiresApproval {
                    do { try unregister() }
                    catch { if modernState() != .disabled { throw error } }
                }
                if exists { try files.removeItem(at: agentURL) }
                let actual = state()
                guard actual == .disabled else { throw LoginItemError.message("系统仍显示登录启动未关闭，请检查系统登录项设置。") }
                return actual
            }
            try validateInstallation()
            if modern != .enabled && modern != .requiresApproval {
                if exists && legacyState(agentURL) == .requiresApproval { return .requiresApproval }
                do { try register() }
                catch {
                    let actual = modernState()
                    if actual != .enabled && actual != .requiresApproval { throw error }
                }
            }
            let actual = modernState()
            guard actual == .enabled || actual == .requiresApproval else {
                throw LoginItemError.message("系统没有确认登录项注册，尚未开启。请重试或检查系统登录项设置。")
            }
            // Delete the obsolete open-based entry only after macOS confirms
            // registration. An error retains the user's old recovery material.
            if exists {
                do { try files.removeItem(at: agentURL) }
                catch {
                    let error = error as NSError
                    throw LoginItemError.message("系统登录项已注册，但旧启动配置未能清理。\n错误记录：\(error.domain)（\(error.code)）。")
                }
            }
            return actual
        } catch let error as LoginItemError { throw error }
        catch {
            let error = error as NSError
            throw LoginItemError.message("无法\(enabled ? "开启" : "关闭")登录启动，请检查系统“登录项”设置。\n错误记录：\(error.domain)（\(error.code)）。")
        }
    }
    func openSystemSettings() { showSettings() }
    private var exists: Bool { (try? files.attributesOfItem(atPath: agentURL.path)) != nil }
    private func ownedAgent() throws -> [String: Any] {
        let attributes = try files.attributesOfItem(atPath: agentURL.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let record = try PropertyListSerialization.propertyList(from: Data(contentsOf: agentURL), format: nil) as? [String: Any],
              record["Label"] as? String == Self.label,
              record["AssociatedBundleIdentifiers"] as? [String] == [bundleID],
              let arguments = record["ProgramArguments"] as? [String],
              arguments.count == 3, Array(arguments.prefix(2)) == ["/usr/bin/open", "-g"],
              record["RunAtLoad"] as? Bool == true else {
            throw LoginItemError.message("登录启动配置无法确认归属，已保留原文件，请检查系统登录项设置。")
        }
        return record
    }
    private func validateInstallation() throws {
        guard installationRoots.contains(where: { appURL.resolvingSymlinksInPath().deletingLastPathComponent() == $0.resolvingSymlinksInPath() }),
              appURL.pathExtension == "app", let bundle = Bundle(url: appURL), bundle.bundleIdentifier == bundleID,
              let executable = bundle.executableURL, files.isExecutableFile(atPath: executable.path) else {
            throw LoginItemError.message("请先把轻舟放入“应用程序”文件夹，并从那里打开，再开启登录启动。")
        }
    }
}

enum LoginItemError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}
