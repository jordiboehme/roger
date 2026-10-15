import Foundation

extension Array where Element == String {
    /// "a", "a and b", "a, b and c": no Oxford comma, unlike `ListFormatter`.
    var joinedAsList: String {
        guard let last else { return "" }
        guard count > 1 else { return last }
        return dropLast().joined(separator: ", ") + " and " + last
    }
}
