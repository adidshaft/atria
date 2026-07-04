import Compression
import Foundation

enum AtriaBackupCompression {
    static func compressedArchiveData(from data: Data) throws -> Data {
        try transform(data, operation: COMPRESSION_STREAM_ENCODE)
    }

    static func archivePayloadData(from data: Data, fileExtension: String) throws -> Data {
        guard fileExtension == "gz" else { return data }
        return try transform(data, operation: COMPRESSION_STREAM_DECODE)
    }

    private static func transform(_ data: Data, operation: compression_stream_operation) throws -> Data {
        guard !data.isEmpty else { return Data() }
        return try data.withUnsafeBytes { sourceBuffer in
            guard let sourceBaseAddress = sourceBuffer.bindMemory(to: UInt8.self).baseAddress else {
                return Data()
            }
            let pageSize = 16 * 1024
            let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: pageSize)
            defer { destination.deallocate() }

            var stream = compression_stream(dst_ptr: destination,
                                            dst_size: pageSize,
                                            src_ptr: sourceBaseAddress,
                                            src_size: data.count,
                                            state: nil)
            var status = compression_stream_init(&stream, operation, COMPRESSION_ZLIB)
            guard status != COMPRESSION_STATUS_ERROR else {
                throw CocoaError(.fileWriteUnknown)
            }
            defer { compression_stream_destroy(&stream) }

            var output = Data()
            repeat {
                status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                switch status {
                case COMPRESSION_STATUS_OK, COMPRESSION_STATUS_END:
                    let produced = pageSize - stream.dst_size
                    if produced > 0 {
                        output.append(destination, count: produced)
                    }
                    stream.dst_ptr = destination
                    stream.dst_size = pageSize
                default:
                    throw CocoaError(.fileReadCorruptFile)
                }
            } while status == COMPRESSION_STATUS_OK

            return output
        }
    }
}
