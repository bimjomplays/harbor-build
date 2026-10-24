import SwiftUI

extension ISO8601DateFormatter {
    static let dateOnly: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withFullDate]; return f }()
}
