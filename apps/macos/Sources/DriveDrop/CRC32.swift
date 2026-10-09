import Foundation

/// CRC32 (IEEE 802.3, reflected poly 0xEDB88320).
///
/// UniFi Drive requires the tus `checksum` Upload-Metadata field to be this value as
/// 8 lowercase hex chars. Every PATCH still answers 204 when it is wrong — the session is
/// only discarded at finalize — so this has to be correct or uploads silently vanish.
enum CRC32 {
    private static let table: [UInt32] = {
        (0..<256).map { i -> UInt32 in
            var c = UInt32(i)
            for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
            return c
        }
    }()

    static func value(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let p = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            for i in 0..<raw.count {
                crc = table[Int((crc ^ UInt32(p[i])) & 0xFF)] ^ (crc >> 8)
            }
        }
        return crc ^ 0xFFFF_FFFF
    }

    /// What Drive wants: 8 lowercase hex characters, base64-encoded by the caller.
    static func hex(_ data: Data) -> String {
        String(format: "%08x", value(data))
    }
}
