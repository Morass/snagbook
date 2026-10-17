import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

// A content checksum avoids treating equal-sized edits as an unchanged destination.
enum ContentDigest {
    static func file(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        #if canImport(CryptoKit)
        var digest = SHA256()
        while let data = try file.read(upToCount: 1_048_576), !data.isEmpty { digest.update(data: data) }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
        #else
        var digest = PortableSHA256()
        while let data = try file.read(upToCount: 1_048_576), !data.isEmpty { digest.update(data) }
        return digest.finish()
        #endif
    }
}

struct PortableSHA256 {
    private var state: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
    private var tail: [UInt8] = []
    private var count: UInt64 = 0
    private static let constants: [UInt32] = [
        0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
        0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
        0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
        0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
        0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
        0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
        0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
        0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2]
    private func rotate(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }
    mutating func update(_ data: Data) {
        count += UInt64(data.count)
        let bytes = tail + data
        var offset = 0
        while offset + 64 <= bytes.count {
            block(Array(bytes[offset..<offset + 64]))
            offset += 64
        }
        tail = Array(bytes[offset...])
    }
    private mutating func block(_ bytes: [UInt8]) {
        var w = [UInt32](repeating: 0, count: 64)
        for i in 0..<16 { let j = i * 4; w[i] = UInt32(bytes[j]) << 24 | UInt32(bytes[j+1]) << 16 | UInt32(bytes[j+2]) << 8 | UInt32(bytes[j+3]) }
        for i in 16..<64 {
            let a = w[i-15], b = w[i-2]
            w[i] = w[i-16] &+ (rotate(a,7) ^ rotate(a,18) ^ (a >> 3)) &+ w[i-7] &+ (rotate(b,17) ^ rotate(b,19) ^ (b >> 10))
        }
        var a=state[0], b=state[1], c=state[2], d=state[3], e=state[4], f=state[5], g=state[6], h=state[7]
        for i in 0..<64 {
            let t1 = h &+ (rotate(e,6) ^ rotate(e,11) ^ rotate(e,25)) &+ ((e & f) ^ (~e & g)) &+ Self.constants[i] &+ w[i]
            let t2 = (rotate(a,2) ^ rotate(a,13) ^ rotate(a,22)) &+ ((a & b) ^ (a & c) ^ (b & c))
            h=g; g=f; f=e; e=d &+ t1; d=c; c=b; b=a; a=t1 &+ t2
        }
        for (i, value) in [a,b,c,d,e,f,g,h].enumerated() { state[i] = state[i] &+ value }
    }
    mutating func finish() -> String {
        let bits = count * 8
        var padding: [UInt8] = [0x80]
        while (tail.count + padding.count) % 64 != 56 { padding.append(0) }
        padding += (0..<8).reversed().map { UInt8(truncatingIfNeeded: bits >> ($0 * 8)) }
        update(Data(padding))
        return state.map { String(format: "%08x", $0) }.joined()
    }
}
