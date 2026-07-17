import Foundation

/// Research tool: decode raw stream-5 IMU frame CSVs into per-sample
/// accelerometer/gyro rows for offline detector iteration. Output is
/// evidence-faithful: one row per decoded 100 Hz sample, with the source
/// frame's device timestamp, so window boundaries and gaps stay auditable.
/// usage: dump_imu_samples <csv-directory> <start-ms> <end-ms> <out.csv>
@main
enum DumpIMUSamples {
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count == 5,
              let startMS = Int64(args[2]),
              let endMS = Int64(args[3]) else {
            FileHandle.standardError.write(Data("usage: dump_imu_samples <csv-directory> <start-ms> <end-ms> <out.csv>\n".utf8))
            exit(64)
        }
        let directory = URL(fileURLWithPath: args[1])
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { throw CocoaError(.fileReadNoSuchFile) }
        let files = enumerator.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "csv" }

        var rows: [(sampleAtMS: Int64, frame: Data)] = []
        for file in files {
            var isHeader = true
            let content = try String(contentsOf: file, encoding: .utf8)
            content.enumerateLines { line, _ in
                if isHeader { isHeader = false; return }
                let columns = line.split(separator: ",", omittingEmptySubsequences: false)
                guard columns.count >= 6,
                      let frame = data(hex: columns[5]),
                      let deviceTimestamp = AtriaR10MotionDecoder.validatedDeviceTimestamp(frame: frame),
                      deviceTimestamp > 0 else { return }
                let sampleAtMS = Int64(deviceTimestamp) * 1_000
                guard sampleAtMS >= startMS, sampleAtMS < endMS else { return }
                rows.append((sampleAtMS, frame))
            }
        }
        rows.sort { $0.sampleAtMS < $1.sampleAtMS }

        var seen = Set<Int64>()
        var out = "device_ts,sample_index,ax,ay,az,amag,gx,gy,gz\n"
        var decoded = 0
        for row in rows {
            guard seen.insert(row.sampleAtMS).inserted else { continue }
            guard let frame = AtriaR10MotionDecoder.decode(frame: row.frame) else { continue }
            decoded += 1
            let accel = frame.acceleration
            let gyro = frame.rotationRate
            for i in accel.indices {
                let a = accel[i]
                let g = i < gyro.count ? gyro[i] : nil
                out += "\(frame.deviceTimestamp),\(i),\(a.x),\(a.y),\(a.z),\(a.magnitude),"
                out += "\(g?.x ?? 0),\(g?.y ?? 0),\(g?.z ?? 0)\n"
            }
        }
        try out.write(toFile: args[4], atomically: true, encoding: .utf8)
        FileHandle.standardError.write(Data("decoded_frames=\(decoded) rows_written\n".utf8))
    }

    private static func data(hex: Substring) -> Data? {
        let chars = Array(hex)
        guard chars.count % 2 == 0 else { return nil }
        var data = Data(capacity: chars.count / 2)
        var index = 0
        while index < chars.count {
            guard let high = chars[index].hexDigitValue,
                  let low = chars[index + 1].hexDigitValue else { return nil }
            data.append(UInt8(high << 4 | low))
            index += 2
        }
        return data
    }
}
