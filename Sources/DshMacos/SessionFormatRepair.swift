import Foundation

private let v0SessionLogName = "session.jsonl"
private let v0SessionZstdName = "session.jsonl.zstd"
private let originBackupSuffix = ".origin-backup"

func sanitizeReleasedV0SessionJSONL(_ text: String) -> (text: String, changedLines: Int) {
    var changedLines = 0
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    let rewritten = lines.map { line -> String in
        let original = String(line)
        guard let sanitized = sanitizedPermissionPresetLine(original) else {
            return original
        }
        changedLines += 1
        return sanitized
    }
    return (rewritten.joined(separator: "\n"), changedLines)
}

func sanitizedPermissionPresetLine(_ line: String) -> String? {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.contains("\"permission/preset\""), trimmed.contains("\"origin\"") else {
        return nil
    }
    guard
        let data = trimmed.data(using: .utf8),
        var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        object["type"] as? String == "permission/preset",
        var payload = object["data"] as? [String: Any],
        payload["origin"] != nil
    else {
        return nil
    }
    payload.removeValue(forKey: "origin")
    object["data"] = payload
    guard
        let encoded = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
        let text = String(data: encoded, encoding: .utf8)
    else {
        return nil
    }
    return text
}

func isLegacyV0SessionLog(_ filename: String) -> Bool {
    filename == v0SessionLogName || filename == v0SessionZstdName
}

@discardableResult
func repairLegacyHarnessSessions(
    in home: URL,
    fileManager: FileManager = .default,
    zstdNode: URL? = resolvedZstdNodeURL()
) throws -> Int {
    let sessions = home.appendingPathComponent("sessions", isDirectory: true)
    guard fileManager.fileExists(atPath: sessions.path) else { return 0 }

    var repaired = 0
    var firstError: Error?
    let enumerator = fileManager.enumerator(
        at: sessions,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
    )
    while let file = enumerator?.nextObject() as? URL {
        guard isLegacyV0SessionLog(file.lastPathComponent) else { continue }
        do {
            if try repairLegacySessionLog(at: file, fileManager: fileManager, zstdNode: zstdNode) {
                repaired += 1
            }
        } catch {
            if firstError == nil { firstError = error }
        }
    }
    if repaired == 0, let firstError {
        throw firstError
    }
    return repaired
}

private func repairLegacySessionLog(
    at url: URL,
    fileManager: FileManager,
    zstdNode: URL?
) throws -> Bool {
    let original: Data
    let isZstd = url.lastPathComponent.hasSuffix(".zstd")
    if isZstd {
        guard let node = zstdNode else { return false }
        original = try transcodeZstdSession(mode: "decode", input: url, node: node)
    } else {
        original = try Data(contentsOf: url)
    }

    guard let text = String(data: original, encoding: .utf8) else { return false }
    let sanitized = sanitizeReleasedV0SessionJSONL(text)
    let needsReframe: Bool
    if isZstd, let node = zstdNode {
        needsReframe = !(try zstdSessionHasStandaloneHeaderFrame(at: url, node: node))
    } else {
        needsReframe = false
    }
    guard sanitized.changedLines > 0 || needsReframe else { return false }

    let backup = URL(fileURLWithPath: url.path + originBackupSuffix)
    if !fileManager.fileExists(atPath: backup.path) {
        try fileManager.copyItem(at: url, to: backup)
    }

    let payload = Data(sanitized.text.utf8)
    if isZstd {
        try transcodeZstdSession(mode: "encode", inputData: payload, output: url, node: zstdNode!)
    } else {
        try payload.write(to: url, options: .atomic)
    }
    return true
}

private func transcodeZstdSession(mode: String, input: URL, node: URL) throws -> Data {
    let output = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("bin")
    defer { try? FileManager.default.removeItem(at: output) }
    try runZstdSessionHelper(mode: mode, input: input, output: output, node: node)
    return try Data(contentsOf: output)
}

private func transcodeZstdSession(mode: String, inputData: Data, output: URL, node: URL) throws {
    let input = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("jsonl")
    defer { try? FileManager.default.removeItem(at: input) }
    try inputData.write(to: input, options: .atomic)
    let encoded = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("zstd")
    defer { try? FileManager.default.removeItem(at: encoded) }
    try runZstdSessionHelper(mode: mode, input: input, output: encoded, node: node)
    let payload = try Data(contentsOf: encoded)
    try payload.write(to: output, options: .atomic)
}

private func runZstdSessionHelper(mode: String, input: URL, output: URL, node: URL) throws {
    let process = Process()
    let stderr = Pipe()
    process.executableURL = node
    process.arguments = [
        "--input-type=module",
        "-e",
        zstdSessionHelperSource,
        mode,
        input.path,
        output.path
    ]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = stderr
    process.standardInput = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        let message = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        throw AppError.message(message?.isEmpty == false ? message! : "无法编解码会话压缩包")
    }
}

func zstdSessionHasStandaloneHeaderFrame(at url: URL, node: URL) throws -> Bool {
    let process = Process()
    let stderr = Pipe()
    process.executableURL = node
    process.arguments = [
        "--input-type=module",
        "-e",
        zstdSessionHelperSource,
        "check",
        url.path,
        url.path
    ]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = stderr
    process.standardInput = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    if process.terminationStatus == 0 { return true }
    if process.terminationStatus == 2 { return false }
    let message = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    throw AppError.message(message?.isEmpty == false ? message! : "无法检查会话压缩包")
}

private let zstdSessionHelperSource = #"""
import { readFileSync, writeFileSync } from "node:fs";
import { constants, zstdCompressSync, zstdDecompressSync } from "node:zlib";

const ZSTD_MAGIC = 4247762216;

const mode = process.argv[1];
const inputPath = process.argv[2];
const outputPath = process.argv[3];
const source = readFileSync(inputPath);

const opts = { params: { [constants.ZSTD_c_checksumFlag]: 1 } };

if (mode === "decode") {
  const { frames, tornStart } = scanZstdFrames(source);
  if (tornStart !== undefined) throw new Error(`incomplete zstd frame at byte ${tornStart}`);
  writeFileSync(outputPath, Buffer.concat(frames.map((frame) => zstdDecompressSync(source.subarray(frame.start, frame.end)))));
} else if (mode === "encode") {
  writeFileSync(outputPath, encodeHeaderSeparatedFrames(source, opts));
} else if (mode === "check") {
  const { frames, tornStart } = scanZstdFrames(source);
  if (tornStart !== undefined || frames.length === 0) process.exit(2);
  const first = zstdDecompressSync(source.subarray(frames[0].start, frames[0].end));
  process.exit(first.length > 0 && first.indexOf(10) === first.length - 1 ? 0 : 2);
} else {
  throw new Error(`unknown zstd helper mode ${mode}`);
}

function encodeHeaderSeparatedFrames(source, options) {
  let text = source.toString("utf8");
  if (!text.includes("\n")) text += "\n";
  const newline = text.indexOf("\n");
  const encoded = Buffer.from(text, "utf8");
  const header = encoded.subarray(0, newline + 1);
  const rest = encoded.subarray(newline + 1);
  const frames = [zstdCompressSync(header, options)];
  if (rest.length > 0) frames.push(zstdCompressSync(rest, options));
  return Buffer.concat(frames);
}

function scanZstdFrames(buffer) {
  const frames = [];
  let offset = 0;
  while (offset < buffer.length) {
    const start = offset;
    if (buffer.length - offset < 4) return { frames, tornStart: start };
    if (buffer.readUInt32LE(offset) !== ZSTD_MAGIC) throw new Error(`invalid zstd magic at byte ${offset}`);
    offset += 4;
    if (offset === buffer.length) return { frames, tornStart: start };
    const descriptor = buffer.readUInt8(offset);
    offset += 1;
    if ((descriptor & 24) !== 0) throw new Error(`reserved zstd frame-header bit at byte ${offset - 1}`);
    const contentSizeFlag = descriptor >>> 6;
    const singleSegment = (descriptor & 32) !== 0;
    const checksum = (descriptor & 4) !== 0;
    const dictionaryFlag = descriptor & 3;
    const dictionaryBytes = dictionaryFlag === 3 ? 4 : dictionaryFlag;
    const contentSizeBytes = contentSizeFlag === 0 ? (singleSegment ? 1 : 0) : (1 << contentSizeFlag);
    const remainingHeaderBytes = (singleSegment ? 0 : 1) + dictionaryBytes + contentSizeBytes;
    if (buffer.length - offset < remainingHeaderBytes) return { frames, tornStart: start };
    offset += remainingHeaderBytes;
    for (;;) {
      if (buffer.length - offset < 3) return { frames, tornStart: start };
      const blockHeader = buffer.readUIntLE(offset, 3);
      offset += 3;
      const lastBlock = (blockHeader & 1) !== 0;
      const blockType = (blockHeader >>> 1) & 3;
      const blockSize = blockHeader >>> 3;
      if (blockType === 3) throw new Error(`reserved zstd block type at byte ${offset - 3}`);
      const payloadBytes = blockType === 1 ? 1 : blockSize;
      if (buffer.length - offset < payloadBytes) return { frames, tornStart: start };
      offset += payloadBytes;
      if (lastBlock) break;
    }
    if (checksum) {
      if (buffer.length - offset < 4) return { frames, tornStart: start };
      offset += 4;
    }
    frames.push({ start, end: offset });
  }
  return { frames };
}
"""#
