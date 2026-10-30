import Foundation
#if canImport(Libbox)
import Libbox

enum CompanySDK {
    static func export(_ controller: CompanymobileController) throws -> String {
        var error: NSError?; let value = controller.exportSession(&error); if let error { throw error }; return value
    }
    static func export(_ attempt: CompanymobileTunnelAttempt) throws -> String {
        var error: NSError?; let value = attempt.exportSession(&error); if let error { throw error }; return value
    }
    static func verify(_ attempt: CompanymobileTunnelAttempt, target: String) throws -> String {
        var error: NSError?; let value = attempt.verify(target, error: &error); if let error { throw error }; return value
    }
}
#endif
