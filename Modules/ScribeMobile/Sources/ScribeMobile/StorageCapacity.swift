import Foundation

public enum StorageCapacity {
    public static let recordingReserve: Int64 = 64 * 1_024 * 1_024
    public static func require(_ bytes: Int64, at url: URL) throws {
        #if os(iOS)
        let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let available = values.volumeAvailableCapacityForImportantUsage, available < bytes {
            throw MobileError.message("There is not enough free storage. Free some space before continuing.")
        }
        #endif
    }
}
