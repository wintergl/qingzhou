import Foundation

struct AuthMethod: Decodable, Hashable {
    let loginDomain: String
    let authType: String
    let authName: String
}

struct ProbeInfo: Decodable {
    let origin: String
    let fingerprint: String
    let subject: String
    let validTo: String
    let nameMatches: Bool
    let selfSigned: Bool
    let methods: [AuthMethod]
    let systemTrusted: Bool?
    let validFrom: String?

    init(origin: String, fingerprint: String, subject: String, validTo: String, nameMatches: Bool,
         selfSigned: Bool, methods: [AuthMethod], systemTrusted: Bool? = nil, validFrom: String? = nil) {
        self.origin = origin; self.fingerprint = fingerprint; self.subject = subject; self.validTo = validTo
        self.nameMatches = nameMatches; self.selfSigned = selfSigned; self.methods = methods
        self.systemTrusted = systemTrusted; self.validFrom = validFrom
    }
}

struct ResourceRow: Codable, Identifiable {
    let id: String
    let appID: String
    let name: String
    let address: String
    let ports: String
    let network: String
    let accessModel: String
}

struct ResourceResult: Decodable {
    let rows: [ResourceRow]
    let appCount: Int
    let dns: [String]
    let gateways: [String]
    let fetchedAt: String
}

struct ChallengePoint: Codable {
    let x: Int
    let y: Int
}

struct AuthChallenge: Decodable, Identifiable {
    let id: String
    let kind: String
    let title: String
    let message: String
    let imageBase64: String?
    let url: String?
    var username: String? = nil
    var requireUsername: Bool? = nil
    var rules: [String]? = nil
    var errorMessage: String? = nil
}

struct HelperEvent: Decodable {
    let type: String
    let stage: String?
    let message: String?
    let username: String?
    let probe: ProbeInfo?
    let resources: ResourceResult?
    let tunnel: TunnelProof?
    let challenge: AuthChallenge?
    var code: String? = nil
    var id: String? = nil

    var loginIssue: CompanyLoginIssue? {
        guard type == "error", stage == "login" else { return nil }
        if code == CompanyLoginIssue.passwordChangeRequired.rawValue { return .passwordChangeRequired }
        // Keep the recovery flow usable with an older bundled helper.
        if code == nil, message == "unsupported next authentication service: auth/modifyPwd" { return .passwordChangeRequired }
        return nil
    }
}

enum CompanyLoginIssue: String {
    case passwordChangeRequired = "password_change_required"

    var title: String { "需要修改接入密码" }
    var message: String { "接入网关要求先修改密码。请在官方 aTrust 完成修改并断开私有网络连接，再回轻舟输入新密码登录。" }
}

struct TunnelProof: Decodable {
    let port: Int
    let target: String
    let httpStatus: Int
    let elapsedMs: Int
    let sent: Int
    let received: Int
    let verifiedAt: String
    let transport: String
}

struct CompanyNetworkContext: Decodable { let interfaceName: String? }

struct CompanyRoutingState: Decodable {
    let active: Bool
    let verified: Bool
    let recovering: Bool
    let recoveryCount: Int
    let proxyName: String?
    let ruleCount: Int
    let routes: [String]
    let lastError: String?
    let proof: SystemBusinessProof?
    let internet: InternetHealthProof?
}
struct InternetHealthProof: Decodable {
    let result: InternetConnectivity
    let checkedAt: String
}
struct InternetConnectivity: Decodable {
    let ok: Bool
    let httpStatus: Int?
    let elapsedMs: Int
    let error: String?
}
struct SystemBusinessProof: Decodable {
    let target: String
    let httpStatus: Int
    let elapsedMs: Int
    let interfaceName: String
    let sourcePort: Int
    let chains: [String]
    let corePid: Int
    let verifiedAt: String
}

struct TimelineItem: Identifiable {
    let id = UUID()
    let time = Date()
    let message: String
}

enum TestPhase: String {
    case pending = "待验证", running = "进行中", passed = "通过", failed = "失败"
}
struct CompanyPreview {
    let probe: ProbeInfo
    var resources: ResourceResult?
    var tunnel: TunnelProof?
    var routing: CompanyRoutingState?
}
