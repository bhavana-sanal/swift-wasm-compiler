import Testing
@testable import TernCore

@Suite struct LEB128Tests {
    static let unsignedCases: [(UInt64, [UInt8])] = [
        (0, [0x00]),
        (1, [0x01]),
        (127, [0x7F]),
        (128, [0x80, 0x01]),
        (255, [0xFF, 0x01]),
        (16_383, [0xFF, 0x7F]),
        (16_384, [0x80, 0x80, 0x01]),
        (624_485, [0xE5, 0x8E, 0x26]),
        (UInt64(UInt32.max), [0xFF, 0xFF, 0xFF, 0xFF, 0x0F]),
        (UInt64.max, [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01]),
    ]

    static let signedCases: [(Int64, [UInt8])] = [
        (0, [0x00]),
        (1, [0x01]),
        (-1, [0x7F]),
        (63, [0x3F]),
        (64, [0xC0, 0x00]),  // 0x40 alone would read back as -64
        (-64, [0x40]),
        (-65, [0xBF, 0x7F]),
        (127, [0xFF, 0x00]),
        (-128, [0x80, 0x7F]),
        (-123_456, [0xC0, 0xBB, 0x78]),
        (Int64(Int32.max), [0xFF, 0xFF, 0xFF, 0xFF, 0x07]),
        (Int64(Int32.min), [0x80, 0x80, 0x80, 0x80, 0x78]),
        (Int64.max, [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00]),
        (Int64.min, [0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x7F]),
    ]

    @Test(arguments: unsignedCases)
    func unsigned(value: UInt64, expected: [UInt8]) {
        var bytes: [UInt8] = []
        bytes.appendUnsignedLEB128(value)
        #expect(bytes == expected)
    }

    @Test(arguments: signedCases)
    func signed(value: Int64, expected: [UInt8]) {
        var bytes: [UInt8] = []
        bytes.appendSignedLEB128(value)
        #expect(bytes == expected)
    }

    @Test func signedRoundTripsAroundEveryGroupBoundary() {
        var values: [Int64] = [.min, .max]
        for shift in stride(from: 0, to: 63, by: 7) {
            let edge = Int64(1) << shift
            values += [edge - 1, edge, edge + 1, -edge - 1, -edge, -edge + 1]
        }
        for value in values {
            var bytes: [UInt8] = []
            bytes.appendSignedLEB128(value)
            #expect(decodeSigned(bytes) == value, "round trip of \(value)")
        }
    }

    /// Reference decoder from the spec, independent of the encoder.
    private func decodeSigned(_ bytes: [UInt8]) -> Int64 {
        var result: Int64 = 0
        var shift: Int64 = 0
        for byte in bytes {
            result |= Int64(byte & 0x7F) << shift
            shift += 7
            if byte & 0x80 == 0 {
                if shift < 64, byte & 0x40 != 0 { result |= -1 << shift }
                break
            }
        }
        return result
    }
}
