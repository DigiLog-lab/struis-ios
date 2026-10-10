import Foundation
import Darwin

/// Trusted workspace bridge only. It never receives a root, owner, generation or
/// pointer from a guest message, and never falls back to pathname file operations.
nonisolated final class WorkspaceOperationBroker: @unchecked Sendable {
    nonisolated enum Access { case readOnly, readWrite }
    /// Trusted construction policy, never decoded from a guest request.
    nonisolated struct DescriptorLimits: Sendable {
        let readExtent: UInt64
        let writeExtent: UInt64
        init(readExtent: UInt64, writeExtent: UInt64) throws {
            guard readExtent > 0, writeExtent > 0, readExtent <= UInt64(Int64.max), writeExtent <= UInt64(Int64.max) else { throw Failure(code: EINVAL) }
            self.readExtent = readExtent; self.writeExtent = writeExtent
        }
    }
    nonisolated struct DescriptorPolicy: Sendable {
        let readExtent: UInt64
        let writeExtent: UInt64
        let configured: Bool
    }
    nonisolated struct OpenOptions: OptionSet, Sendable {
        let rawValue: UInt32
        static let read = Self(rawValue: UInt32(HYOTAN_OPEN_READ))
        static let write = Self(rawValue: UInt32(HYOTAN_OPEN_WRITE))
        static let create = Self(rawValue: UInt32(HYOTAN_OPEN_CREATE))
        static let exclusive = Self(rawValue: UInt32(HYOTAN_OPEN_EXCLUSIVE))
        static let truncate = Self(rawValue: UInt32(HYOTAN_OPEN_TRUNCATE))
        static let append = Self(rawValue: UInt32(HYOTAN_OPEN_APPEND))
    }
    nonisolated struct FileHandle: Sendable {
        fileprivate let instanceID: UUID
        fileprivate let value: UInt64
    }
    nonisolated struct Metadata: Sendable {
        let bytes: UInt64
        let isDirectory: Bool
        let createdAtMilliseconds: UInt64?
        let modifiedAtMilliseconds: UInt64?
        fileprivate init(_ value: HyotanOperationMetadata) {
            bytes = value.bytes
            isDirectory = value.flags & UInt32(HYOTAN_METADATA_DIRECTORY) != 0
            createdAtMilliseconds = value.flags & UInt32(HYOTAN_METADATA_CREATED) != 0 ? value.created_at_ms : nil
            modifiedAtMilliseconds = value.flags & UInt32(HYOTAN_METADATA_MODIFIED) != 0 ? value.modified_at_ms : nil
        }
    }
    nonisolated struct Failure: Error, LocalizedError, Sendable, Equatable {
        let code: Int32
        var errorDescription: String? { String(cString: hyotan_operations_error_message(code)) }
    }

    private let lock = NSLock()
    private let instanceID = UUID()
    private var workspace: OpaquePointer?

    /// The caller has verified directory provenance and retains its FD. C owns
    /// a duplicate. owner/generation are trusted lifecycle context, not authority
    /// requested by a model or WK guest.
    nonisolated init(trustedDirectoryFD: Int32, owner: String, generation: UInt64, access: Access, descriptorLimits: DescriptorLimits? = nil) throws {
        // C takes a NUL-terminated owner; do not silently truncate an embedded NUL.
        guard !owner.utf8.contains(0), (1...256).contains(owner.utf8.count) else { throw Failure(code: EINVAL) }
        var instance: OpaquePointer?
        let code = owner.withCString {
            let permissions = UInt32(access == .readOnly ? HYOTAN_WORKSPACE_READ_ONLY : HYOTAN_WORKSPACE_READ_WRITE)
            if let descriptorLimits {
                return hyotan_operations_create_with_descriptor_limits(trustedDirectoryFD, $0, generation, permissions,
                    descriptorLimits.readExtent, descriptorLimits.writeExtent, &instance)
            }
            return hyotan_operations_create(trustedDirectoryFD, $0, generation, permissions, &instance)
        }
        try Self.check(code)
        guard let instance else { throw Failure(code: EIO) }
        workspace = instance
    }

    deinit {
        lock.lock()
        if let workspace { _ = hyotan_operations_destroy(workspace) }
        workspace = nil
        lock.unlock()
    }

    /// Waits for any in-flight operation, then permanently cancels this grant.
    nonisolated func revoke() throws { try withWorkspace { try Self.check(hyotan_operations_revoke($0)) } }

    /// Serializes pointer destruction with all C calls. Further requests fail.
    nonisolated func destroy() throws {
        lock.lock(); defer { lock.unlock() }
        guard let current = workspace else { return }
        try Self.check(hyotan_operations_destroy(current))
        workspace = nil
    }

    /// Read-only live bootstrap observation, not cached permission after revoke.
    nonisolated func descriptorPolicy() throws -> DescriptorPolicy {
        try withWorkspace { workspace in
            var readExtent: UInt64 = 0, writeExtent: UInt64 = 0
            var configured: UInt32 = 0
            try Self.check(hyotan_operations_descriptor_limits(workspace, &readExtent, &writeExtent, &configured))
            guard configured <= 1, readExtent > 0, writeExtent > 0 else { throw Failure(code: EIO) }
            return DescriptorPolicy(readExtent: readExtent, writeExtent: writeExtent, configured: configured == 1)
        }
    }

    nonisolated func open(_ path: String, options: OpenOptions) throws -> FileHandle {
        try withWorkspace { workspace in
            var handle: UInt64 = 0
            try withPath(path) { try Self.check(hyotan_operations_open(workspace, $0, $1, options.rawValue, &handle)) }
            return FileHandle(instanceID: instanceID, value: handle)
        }
    }

    nonisolated func read(_ handle: FileHandle, offset: UInt64, count: Int) throws -> Data {
        guard (0...1_048_576).contains(count) else { throw Failure(code: count < 0 ? EINVAL : EFBIG) }
        return try withWorkspace { workspace in
            try validate(handle)
            var bytes = [UInt8](repeating: 0, count: count)
            var readCount = 0
            try bytes.withUnsafeMutableBufferPointer {
                try Self.check(hyotan_operations_read_at(workspace, handle.value, offset, count, $0.baseAddress, $0.count, &readCount))
            }
            guard readCount <= count else { throw Failure(code: EIO) }
            return Data(bytes.prefix(readCount))
        }
    }

    /// Returns the actual written byte count. The caller must handle short writes.
    nonisolated func write(_ handle: FileHandle, offset: UInt64, data: Data) throws -> Int {
        try withWorkspace { workspace in
            try validate(handle)
            var written = 0
            try data.withUnsafeBytes {
                try Self.check(hyotan_operations_write_at(workspace, handle.value, offset, $0.bindMemory(to: UInt8.self).baseAddress, $0.count, &written))
            }
            guard written <= data.count else { throw Failure(code: EIO) }
            return written
        }
    }

    nonisolated func truncate(_ handle: FileHandle, length: UInt64) throws {
        try withWorkspace { workspace in try validate(handle); try Self.check(hyotan_operations_truncate(workspace, handle.value, length)) }
    }
    nonisolated func stat(_ handle: FileHandle) throws -> Metadata {
        try withWorkspace { workspace in
            try validate(handle)
            var value = HyotanOperationMetadata()
            try Self.check(hyotan_operations_stat(workspace, handle.value, &value))
            return Metadata(value)
        }
    }
    nonisolated func close(_ handle: FileHandle) throws {
        try withWorkspace { workspace in try validate(handle); try Self.check(hyotan_operations_close(workspace, handle.value)) }
    }
    nonisolated func metadata(_ path: String = "") throws -> Metadata {
        try withWorkspace { workspace in
            var value = HyotanOperationMetadata()
            try withPath(path) { try Self.check(hyotan_operations_metadata(workspace, $0, $1, &value)) }
            return Metadata(value)
        }
    }
    nonisolated func list(_ path: String = "") throws -> [String] {
        try withWorkspace { workspace in
            // C's listing budget is fixed at 1 MiB, including separators.
            var bytes = [UInt8](repeating: 0, count: 1_048_576)
            var written = 0, entries = 0, required = 0
            try withPath(path) { pointer, length in
                try bytes.withUnsafeMutableBufferPointer {
                    try Self.check(hyotan_operations_list(workspace, pointer, length, $0.baseAddress, $0.count, &written, &entries, &required))
                }
            }
            guard written <= bytes.count else { throw Failure(code: EIO) }
            let names = bytes.prefix(written).split(separator: 0, omittingEmptySubsequences: true)
            guard names.count == entries else { throw Failure(code: EIO) }
            return try names.map { guard let name = String(bytes: $0, encoding: .utf8) else { throw Failure(code: EIO) }; return name }
        }
    }
    nonisolated func mkdir(_ path: String) throws {
        try withWorkspace { workspace in try withPath(path) { try Self.check(hyotan_operations_mkdir(workspace, $0, $1)) } }
    }
    nonisolated func remove(_ path: String, recursive: Bool = false) throws {
        try withWorkspace { workspace in try withPath(path) { try Self.check(hyotan_operations_remove(workspace, $0, $1, recursive ? 1 : 0)) } }
    }
    nonisolated func copy(_ source: String, to destination: String, recursive: Bool = false) throws {
        try withWorkspace { workspace in
            try withPath(source) { sourcePointer, sourceLength in
                try withPath(destination) { try Self.check(hyotan_operations_copy(workspace, sourcePointer, sourceLength, $0, $1, recursive ? 1 : 0)) }
            }
        }
    }
    nonisolated func rename(_ source: String, to destination: String) throws {
        try withWorkspace { workspace in
            try withPath(source) { sourcePointer, sourceLength in
                try withPath(destination) { try Self.check(hyotan_operations_rename(workspace, sourcePointer, sourceLength, $0, $1)) }
            }
        }
    }
    nonisolated private func validate(_ handle: FileHandle) throws {
        guard handle.instanceID == instanceID else { throw Failure(code: EACCES) }
    }
    nonisolated private func withWorkspace<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        guard let workspace else { throw Failure(code: EACCES) }
        return try body(workspace)
    }
    nonisolated private func withPath<T>(_ path: String, _ body: (UnsafePointer<UInt8>?, Int) throws -> T) throws -> T {
        guard path.utf8.count <= 4096 else { throw Failure(code: EFBIG) }
        return try Array(path.utf8).withUnsafeBufferPointer { try body($0.baseAddress, $0.count) }
    }
    nonisolated private static func check(_ code: Int32) throws {
        guard code == 0 else { throw Failure(code: code) }
    }
}
