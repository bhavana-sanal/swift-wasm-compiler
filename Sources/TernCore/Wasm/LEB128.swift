/// LEB128 variable-length integers, used for every integer in a Wasm binary.
extension Array where Element == UInt8 {
    mutating func appendUnsignedLEB128(_ value: UInt64) {
        var value = value
        repeat {
            var byte = UInt8(value & 0x7F)
            value >>= 7
            if value != 0 { byte |= 0x80 }
            append(byte)
        } while value != 0
    }

    mutating func appendUnsignedLEB128(_ value: UInt32) {
        appendUnsignedLEB128(UInt64(value))
    }

    /// Emits 7-bit groups until the rest is pure sign extension *and* the sign
    /// bit (0x40) of the last group agrees with it, so decoders sign-extend correctly.
    mutating func appendSignedLEB128(_ value: Int64) {
        var value = value
        while true {
            let byte = UInt8(value & 0x7F)
            value >>= 7  // arithmetic shift keeps the sign
            let done = (value == 0 && byte & 0x40 == 0) || (value == -1 && byte & 0x40 != 0)
            append(done ? byte : byte | 0x80)
            if done { return }
        }
    }
}
