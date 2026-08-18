import Foundation

struct OpenCodeHealth: Decodable, Equatable, Sendable {
    let healthy: Bool
    let version: String
}
