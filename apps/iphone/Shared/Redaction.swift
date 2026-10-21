import Foundation

enum Redaction {
    static func subscriptionURL(_ value: String) -> String {
        guard let url = URL(string: value), let host = url.host else {
            return value.isEmpty ? "" : "<redacted-url>"
        }
        return "\(url.scheme ?? "https")://\(host)/<redacted>"
    }

    static func message(_ value: String) -> String {
        value
            .replacingOccurrences(
                of: #"(?i)(password|passwd|pwd|token|uuid|alterId|cipher)=([^&\s]+)"#,
                with: "$1=<redacted>",
                options: .regularExpression
            )
    }
}
