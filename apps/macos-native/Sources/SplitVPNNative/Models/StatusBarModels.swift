import Foundation

enum ConnectionOperation { case connecting, disconnecting }

enum VPNMenuState: Equatable {
    case loading, disconnected, connected, connecting, disconnecting, error, unknown
    var title: String {
        switch self {
        case .loading: return "读取连接状态…"
        case .disconnected: return "VPN 已关闭"
        case .connected: return "VPN 已开启"
        case .connecting: return "正在连接…"
        case .disconnecting: return "正在断开…"
        case .error: return "连接异常"
        case .unknown: return "连接状态未知"
        }
    }
    var badge: String? {
        switch self {
        case .connected, .disconnected: return nil
        case .error: return "exclamationmark"
        case .loading, .unknown: return "questionmark"
        case .connecting, .disconnecting: return "ellipsis"
        }
    }
}

struct StatusBarIconState: Equatable {
    let personal: VPNMenuState
    let personalConnected: Bool
    let companyConnected: Bool
}

extension StatusBarIconState {
    @MainActor init(store: VPNStore, company: CompanyStore) {
        personal = store.menuState
        personalConnected = store.statusKnown && store.running && (store.status?.mihomo.networkRecovery?.ready ?? true)
        // A helper tunnel can remain connected during resource checks. Only
        // confirmed state may colour the hull after core communication is lost.
        companyConnected = (!company.takeoverEnabled || company.routingKnown)
            && (company.tunnelProof != nil || company.routingState?.active == true)
    }
}

enum CompanyInteraction: Equatable { case account, certificate, challenge }

@MainActor
extension VPNStore {
    var menuState: VPNMenuState {
        if !statusKnown {
            switch core.availability {
            case .unavailable, .closed: return .unknown
            default: return status == nil && error == nil ? .loading : .unknown
            }
        }
        if let connectionOperation { return connectionOperation == .connecting ? .connecting : .disconnecting }
        if status?.mihomo.state == "error" { return .error }
        switch status?.mihomo.networkRecovery?.state {
        case "waiting-network", "recovering": return .connecting
        case "failed", "helper-update-required": return .error
        default: break
        }
        return running ? .connected : .disconnected
    }
    var menuTitle: String {
        if statusKnown, connectionOperation == nil {
            switch status?.mihomo.networkRecovery?.state {
            case "waiting-network": return "等待网络恢复…"
            case "recovering": return "网络恢复中…"
            case "failed": return "网络恢复失败"
            case "helper-update-required": return "连接服务待更新"
            default: break
            }
        }
        if menuState == .connected, status?.mihomo.mode == "subscription-probe" { return "订阅检测中" }
        if menuState == .connected, status?.settings.tun == false { return "代理服务已开启" }
        return menuState.title
    }
    var modeTitle: String {
        guard let status else { return "尚未读取" }
        if status.mihomo.mode == "subscription-probe" { return "订阅检测模式" }
        let routing = status.settings.unknownTraffic == "vpn" ? "默认 VPN" : "默认直连"
        return "\(routing) · \(status.settings.tun ? "TUN 系统分流" : "TUN 已关闭")"
    }
    var canToggleFromMenu: Bool {
        canMutate && !connectionProtected && status?.mihomo.mode != "subscription-probe"
    }
    var connectionServiceUpdateRequired: Bool {
        statusKnown && status?.mihomo.networkRecovery?.helperUpdateRequired == true && !connectionProtected
    }
    var networkRecoveryError: String? { status?.mihomo.networkRecovery?.error }
    var menuRestriction: String? {
        if connectionProtected { return "当前连接由原版维护，请在原版控制连接。" }
        if status?.mihomo.mode == "subscription-probe" { return "订阅检测进行中，请等待检测结束。" }
        if !statusKnown { return "暂时无法确认连接状态，请刷新状态。" }
        return nil
    }
}

@MainActor
extension CompanyStore {
    var menuState: VPNMenuState {
        if terminating { return .disconnecting }
        if connectionOperation == .disconnecting { return .disconnecting }
        if takeoverEnabled && connectionEnabled && !routingKnown { return .unknown }
        if quickPreparing || working || routingState?.recovering == true { return .connecting }
        if connectionEnabled { return .connected }
        if errorMessage != nil { return .error }
        return .disconnected
    }
    var canToggleFromMenu: Bool { !terminating && !working && !quickPreparing }
}
