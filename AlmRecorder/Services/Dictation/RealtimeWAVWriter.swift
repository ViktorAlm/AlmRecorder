import Foundation

enum RealtimeWAVWriter {
    static func write(samples: [Float], sampleRate: Int, to url: URL) throws {
        let channelCount: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let bytesPerSample = Int(bitsPerSample / 8)
        let dataByteCount = samples.count * bytesPerSample

        var data = Data()
        data.reserveCapacity(44 + dataByteCount)
        data.append(contentsOf: Array("RIFF".utf8))
        data.appendLittleEndian(UInt32(36 + dataByteCount))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        data.appendLittleEndian(UInt32(16))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(channelCount)
        data.appendLittleEndian(UInt32(sampleRate))
        data.appendLittleEndian(UInt32(sampleRate * Int(channelCount) * bytesPerSample))
        data.appendLittleEndian(UInt16(Int(channelCount) * bytesPerSample))
        data.appendLittleEndian(bitsPerSample)
        data.append(contentsOf: Array("data".utf8))
        data.appendLittleEndian(UInt32(dataByteCount))

        for sample in samples {
            let clamped = max(-1, min(1, sample))
            let value = Int16(
                clamping: Int((clamped * Float(Int16.max)).rounded())
            )
            data.appendLittleEndian(UInt16(bitPattern: value))
        }
        try data.write(to: url, options: .atomic)
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}
