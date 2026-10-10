// SPDX-License-Identifier: Apache-2.0
import Foundation
import Darwin
@testable import strius

#if DEBUG && targetEnvironment(simulator)
/// Reads only the trusted fixed worker diagnostic file; emits validated numbers
/// from a bounded suffix, never arbitrary stderr/path/auth contents.
func printVirtualPythonProviderDiagnostics() {
    guard let root = NativeRuntimePaths.sharedRoot else { return }
    let path = root.deletingLastPathComponent().appendingPathComponent("Library/worker-stderr.log").path
    let fd = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
    guard fd >= 0 else { return }
    let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    defer { try? file.close() }
    var metadata = stat()
    guard Darwin.fstat(fd, &metadata) == 0, UInt32(metadata.st_mode) & UInt32(S_IFMT) == UInt32(S_IFREG),
          metadata.st_size >= 0 else { return }
    do {
        let size = UInt64(metadata.st_size)
        try file.seek(toOffset: size > 16384 ? size - 16384 : 0)
        let bytes = try file.read(upToCount: 16384) ?? Data()
        let pattern = try NSRegularExpression(pattern: "^STRUIS_VP_PROVIDER stage=([1-5]) errno=([0-9]{1,5})$")
        var count = 0
        for line in String(decoding: bytes, as: UTF8.self).split(separator: "\n") {
            let text = String(line), range = NSRange(text.startIndex..<text.endIndex, in: text)
            guard let match = pattern.firstMatch(in: text, range: range),
                  let stageRange = Range(match.range(at: 1), in: text),
                  let codeRange = Range(match.range(at: 2), in: text),
                  let stage = Int(text[stageRange]), let code = Int(text[codeRange]), code <= 65535 else { continue }
            print("NATIVE_PROVIDER_DIAGNOSTIC stage=\(stage) errno=\(code)")
            count += 1; if count == 32 { break }
        }
    } catch { return }
}
#endif
