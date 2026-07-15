import Compression
import Foundation

enum AtriaBackupCompression {
    /// Imports are user-selected files and therefore untrusted. Keep both
    /// limits explicit: the compressed ceiling prevents an oversized archive
    /// from being read wholesale, while the decoded ceiling stops a tiny zlib
    /// expansion bomb before it can grow an unbounded `Data` buffer.
    static let maximumCompressedArchiveBytes = 64 * 1024 * 1024
    static let maximumDecodedArchiveBytes = 256 * 1024 * 1024

    enum ArchiveError: Error, Equatable {
        case compressedArchiveTooLarge
        case decodedArchiveTooLarge
        case corruptArchive
    }

    static func compressedArchiveData(from data: Data) throws -> Data {
        guard data.count <= maximumDecodedArchiveBytes else {
            throw ArchiveError.decodedArchiveTooLarge
        }
        guard !data.isEmpty else { return Data() }
        let proposed = data.count.addingReportingOverflow(max(64 * 1024, data.count / 8))
        guard !proposed.overflow else { throw ArchiveError.compressedArchiveTooLarge }
        let destinationCapacity = min(maximumCompressedArchiveBytes, proposed.partialValue)
        guard destinationCapacity > 0 else { throw ArchiveError.compressedArchiveTooLarge }
        return try data.withUnsafeBytes { source in
            guard let sourceBase = source.bindMemory(to: UInt8.self).baseAddress else { return Data() }
            let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: destinationCapacity)
            defer { destination.deallocate() }
            let encoded = compression_encode_buffer(destination,
                                                    destinationCapacity,
                                                    sourceBase,
                                                    data.count,
                                                    nil,
                                                    COMPRESSION_ZLIB)
            guard encoded > 0, encoded <= maximumCompressedArchiveBytes else {
                throw ArchiveError.compressedArchiveTooLarge
            }
            return Data(bytes: destination, count: encoded)
        }
    }

    static func archivePayloadData(from data: Data,
                                   fileExtension: String,
                                   maximumCompressedBytes: Int = maximumCompressedArchiveBytes,
                                   maximumDecodedBytes: Int = maximumDecodedArchiveBytes) throws -> Data {
        if fileExtension == "gz" {
            guard data.count <= maximumCompressedBytes else {
                throw ArchiveError.compressedArchiveTooLarge
            }
            return try transform(data,
                                 operation: COMPRESSION_STREAM_DECODE,
                                 outputLimit: maximumDecodedBytes)
        }
        guard data.count <= maximumDecodedBytes else {
            throw ArchiveError.decodedArchiveTooLarge
        }
        return data
    }

    private static func transform(_ data: Data,
                                  operation: compression_stream_operation,
                                  outputLimit: Int) throws -> Data {
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
                // Encoding finalizes only after all source is consumed.
                // Decoding never supplies FINALIZE: Compression may still have
                // buffered expansion after consuming the compressed bytes.
                // A no-source/no-output OK state below is the explicit
                // truncated-stream fail-safe.
                let flags: Int32 = operation == COMPRESSION_STREAM_ENCODE && stream.src_size == 0
                    ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue)
                    : 0
                let sourceBefore = stream.src_size
                status = compression_stream_process(&stream, flags)
                switch status {
                case COMPRESSION_STATUS_OK, COMPRESSION_STATUS_END:
                    let produced = pageSize - stream.dst_size
                    if produced > 0 {
                        guard output.count <= outputLimit - produced else {
                            throw operation == COMPRESSION_STREAM_DECODE
                                ? ArchiveError.decodedArchiveTooLarge
                                : ArchiveError.compressedArchiveTooLarge
                        }
                        output.append(destination, count: produced)
                    }
                    stream.dst_ptr = destination
                    stream.dst_size = pageSize
                    if operation == COMPRESSION_STREAM_DECODE,
                       status == COMPRESSION_STATUS_OK,
                       stream.src_size == 0,
                       sourceBefore == 0,
                       produced == 0 {
                        throw ArchiveError.corruptArchive
                    }
                default:
                    throw ArchiveError.corruptArchive
                }
            } while status == COMPRESSION_STATUS_OK

            // One archive must contain exactly one zlib member. Accepting bytes
            // after END would let an attacker smuggle unvalidated content or
            // concatenate a second payload that our JSON decoder never sees.
            if operation == COMPRESSION_STREAM_DECODE, stream.src_size != 0 {
                throw ArchiveError.corruptArchive
            }

            return output
        }
    }
}
