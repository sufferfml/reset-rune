// INPUT: Private courier envelope bytes from CourierCore.
// OUTPUT: Atomic, bounded storage separate from the reset journal.
// POS: Service-only persistence; see native/README.md.
import Foundation
import CourierCore
import RuneCore

public final class FileCourierStore: CourierStore {
    public let file: URL
    public init(directory: URL) throws {
        let directory = directory.appendingPathComponent("courier")
        try PrivateFiles.ensure(directory)
        file = directory.appendingPathComponent("state.json")
    }
    public func read() throws -> Data? {
        guard let object = try PrivateFiles.read(file) else { return nil }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }
    public func write(_ data: Data) throws {
        guard data.count <= 16 * 1024 * 1024,
              let object = try JSONSerialization.jsonObject(with: data) as? JSONObject else {
            throw RuneError("courier-state-too-large")
        }
        try PrivateFiles.write(file, object)
    }
}
