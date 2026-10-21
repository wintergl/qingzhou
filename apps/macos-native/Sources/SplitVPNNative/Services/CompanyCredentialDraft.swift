import Foundation

/// Hold the manually entered password only until authentication succeeds.
struct CompanyCredentialDraft {
    private var pending: CompanyCredentials?
    mutating func prepare(_ credentials: CompanyCredentials, remember: Bool) { pending = remember ? credentials : nil }
    mutating func cancel() { pending = nil }
    mutating func authenticated(remember: Bool) -> CompanyCredentials? {
        defer { pending = nil }
        return remember ? pending : nil
    }
}
