//
//  FileSize.swift
//  my-cleaner
//

import Foundation

/// On-disk size measurement.
///
/// Uses `URLResourceKey.totalFileAllocatedSize` (with a fallback to
/// `fileAllocatedSize`) to report actual disk usage including compression
/// blocks, rather than logical byte counts. For directories, walks every
/// descendant and sums non-directory allocations.
enum FileSize {

    /// Total allocation in bytes for a file or directory at `url`.
    ///
    /// - Parameters:
    ///   - url: The file or folder to measure.
    ///   - isDirectory: `true` if `url` points at a folder. When `true`
    ///     the function recursively sums every descendant; when `false`
    ///     it returns a single resource lookup.
    /// - Returns: Total allocation in bytes, or `0` if the URL is
    ///   unreadable or has no allocation attribute.
    nonisolated static func of(at url: URL, isDirectory: Bool) -> Int64 {
        if !isDirectory {
            let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
            if let values = try? url.resourceValues(forKeys: keys) {
                return Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
            }
            return 0
        }

        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: { _, _ in true }
        ) else { return 0 }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let values = try? fileURL.resourceValues(forKeys: keys),
               values.isDirectory == false {
                total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
            }
        }
        return total
    }
}
