import Foundation

struct DiagnosticSchedule: Decodable {
    var automatic: Bool
    var pausedReason: String?
    var connectivity: DiagnosticRecord
    var websites: DiagnosticRecord
}
struct DiagnosticRecord: Decodable {
    var state: String
    var checkedAt: String?
    var startedAt: String?
    var nextCheckAt: String?
    var source: String?
    var result: JSONValue?
    var error: String?
    var intervalSeconds: Int?
    var running: Bool { state == "running" }
    var stale: Bool { state == "stale" }
    var sourceLabel: String { source == "automatic" ? "自动检测" : "手动检测" }
}
struct NodeSpeedProgress: Decodable {
    var id: String
    var checked: Int
    var total: Int
    var nodeName: String?
    var phase: String?
    var finished: Bool
    var cancelled: Bool?
    var error: String?
    var result: NodeSpeedResult?
}
struct NodeSpeedResult: Decodable {
    var nodeName: String
    var status: String
    var medianDelayMs: Double?
    var testedAt: String?
    var failureReason: String?
}
enum MeasurementTime {
    static func clock(_ value: String?) -> String {
        RuntimeTime.parse(value)?.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits)) ?? "尚未检测"
    }
}
