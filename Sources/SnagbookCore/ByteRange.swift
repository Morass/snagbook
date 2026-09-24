import Foundation

public enum ByteRange {
    /// An HTTP Range header ("bytes=0-1023", "bytes=500-", "bytes=-200") as an inclusive
    /// (first, last) byte pair within a file of `size` bytes. Nil when it cannot be served,
    /// including multi-range requests.
    public static func parse(_ header: String, size: Int) -> (Int, Int)? {
        guard size > 0, header.hasPrefix("bytes="), !header.contains(",") else { return nil }
        let pieces = header.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
        guard pieces.count == 2 else { return nil }
        if pieces[0].isEmpty {
            guard let n = Int(pieces[1]), n > 0 else { return nil }
            return (max(0, size - n), size - 1)
        }
        guard let a = Int(pieces[0]), a >= 0, a < size else { return nil }
        guard pieces[1].isEmpty || Int(pieces[1]) != nil else { return nil }
        let b = pieces[1].isEmpty ? size - 1 : min(Int(pieces[1])!, size - 1)
        return b >= a ? (a, b) : nil
    }
}
