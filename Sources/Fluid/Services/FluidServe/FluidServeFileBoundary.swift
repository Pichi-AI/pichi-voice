import Darwin
import Foundation

/// Owned directory descriptors for the meeting reader and its one installed skill.
/// No path component, directory entry or opened file may redirect through a symlink.
nonisolated enum FluidServeFileBoundary {
    enum Rejection: Error, LocalizedError {
        case missing, unsafe, tooLarge, limitExceeded, changed, io
        var errorDescription: String? {
            switch self {
            case .missing: "The meeting directory is not available."
            case .tooLarge, .limitExceeded: "Meeting files exceed the read-only command's size or entry limits."
            case .unsafe, .changed, .io: "Meeting files could not be safely read. Symbolic links, nonregular files and changed sources are not served."
            }
        }
    }

    struct Identity: Equatable, Sendable {
        let device: dev_t
        let inode: ino_t
        init(_ metadata: stat) { self.device = metadata.st_dev; self.inode = metadata.st_ino }
    }

    final class Budget: @unchecked Sendable {
        private let lock = NSLock()
        private var remaining: Int
        init(maximumBytes: Int) { self.remaining = maximumBytes }
        func consume(_ count: Int) throws {
            try self.lock.withLock {
                guard count >= 0, count <= self.remaining else { throw Rejection.limitExceeded }
                self.remaining -= count
            }
        }
    }

    struct File: Sendable {
        let data: Data
        let identity: Identity
    }

    final class Directory: @unchecked Sendable {
        let descriptor: Int32
        let identity: Identity

        private init(owned descriptor: Int32) throws {
            var metadata = stat()
            guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFDIR else {
                close(descriptor)
                throw Rejection.unsafe
            }
            self.descriptor = descriptor
            self.identity = Identity(metadata)
        }

        deinit { close(self.descriptor) }

        /// Traverse from an absolute root using no-follow descriptors, including
        /// ancestors. Callers with a system alias such as /tmp supply its trusted
        /// canonical directory before appending their owned fixture/namespace.
        static func open(_ url: URL) throws -> Directory {
            guard url.isFileURL, url.path.hasPrefix("/"), url.path.utf8.count <= 4096 else { throw Rejection.unsafe }
            let components = url.pathComponents.filter { $0 != "/" }
            guard components.allSatisfy(Self.validName) else { throw Rejection.unsafe }
            let descriptor = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            guard descriptor >= 0 else { throw Rejection.io }
            var directory = try Directory(owned: descriptor)
            for component in components { directory = try directory.child(component) }
            return directory
        }

        func child(_ name: String, create: Bool = false) throws -> Directory {
            guard Self.validName(name) else { throw Rejection.unsafe }
            if create, mkdirat(self.descriptor, name, 0o700) != 0, errno != EEXIST { throw Self.openError() }
            let descriptor = openat(self.descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            guard descriptor >= 0 else { throw Self.openError() }
            return try Directory(owned: descriptor)
        }

        /// Stop during enumeration, before an unbounded names array is allocated.
        func names(maximumEntries: Int) throws -> [String] {
            let descriptor = openat(self.descriptor, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            guard descriptor >= 0 else { throw Rejection.io }
            guard let stream = fdopendir(descriptor) else { close(descriptor); throw Rejection.io }
            defer { closedir(stream) }
            var names: [String] = []
            var inspected = 0
            errno = 0
            while let entry = readdir(stream) {
                var bytes = entry.pointee.d_name
                let name = withUnsafePointer(to: &bytes) { pointer in
                    pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
                }
                if name == "." || name == ".." { continue }
                inspected += 1
                guard inspected <= maximumEntries else { throw Rejection.limitExceeded }
                guard Self.validName(name) else { throw Rejection.unsafe }
                names.append(name)
                errno = 0
            }
            guard errno == 0 else { throw Rejection.io }
            return names.sorted()
        }

        func read(_ name: String, maximumBytes: Int, budget: Budget? = nil) throws -> File? {
            guard Self.validName(name), maximumBytes > 0 else { throw Rejection.unsafe }
            let descriptor = openat(self.descriptor, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            guard descriptor >= 0 else {
                if errno == ENOENT { return nil }
                throw Self.openError()
            }
            defer { close(descriptor) }
            return try Self.read(descriptor, maximumBytes: maximumBytes, budget: budget)
        }

        static func read(_ descriptor: Int32, maximumBytes: Int, budget: Budget? = nil) throws -> File {
            var before = stat()
            guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_nlink == 1 else { throw Rejection.unsafe }
            guard before.st_size >= 0, before.st_size <= maximumBytes else { throw Rejection.tooLarge }
            let size = Int(before.st_size)
            try budget?.consume(size)
            var data = Data()
            data.reserveCapacity(size)
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while data.count < size {
                let capacity = min(buffer.count, size - data.count)
                let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, capacity) }
                if count < 0 { if errno == EINTR { continue }; throw Rejection.io }
                if count == 0 { break }
                guard count <= maximumBytes - data.count else { throw Rejection.tooLarge }
                data.append(buffer, count: count)
            }
            var after = stat()
            guard fstat(descriptor, &after) == 0, after.st_mode & S_IFMT == S_IFREG, after.st_nlink == 1, Identity(before) == Identity(after),
                  before.st_size == after.st_size, Int(after.st_size) == data.count,
                  before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
                  before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
                  before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
                  before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else { throw Rejection.changed }
            return File(data: data, identity: Identity(after))
        }

        func matches(_ name: String, identity: Identity) -> Bool {
            guard Self.validName(name) else { return false }
            var metadata = stat()
            return fstatat(self.descriptor, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0
                && metadata.st_mode & S_IFMT == S_IFREG && metadata.st_nlink == 1 && Identity(metadata) == identity
        }

        /// Atomic publication without replacing an unknown leaf. A raced foreign
        /// entry is restored after swap, or retained under the temporary name if
        /// another writer has occupied the original name; it is never deleted.
        func publish(_ data: Data, name: String, replacing file: File?) throws {
            guard Self.validName(name) else { throw Rejection.unsafe }
            let temporary = ".fluidserve-write-" + UUID().uuidString
            let descriptor = openat(self.descriptor, temporary, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
            guard descriptor >= 0 else { throw Rejection.io }
            defer { close(descriptor) }
            var metadata = stat()
            guard fstat(descriptor, &metadata) == 0 else { throw Rejection.io }
            let newIdentity = Identity(metadata)
            defer { if self.matches(temporary, identity: newIdentity) { _ = unlinkat(self.descriptor, temporary, 0) } }
            var written = 0
            while written < data.count {
                let count = data.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress!.advanced(by: written), data.count - written) }
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw Rejection.io }
                written += count
            }
            guard fsync(descriptor) == 0 else { throw Rejection.io }
            if let file {
                guard self.matches(name, identity: file.identity),
                      let current = try self.read(name, maximumBytes: max(1, file.data.count)), current.identity == file.identity, current.data == file.data,
                      renameatx_np(self.descriptor, temporary, self.descriptor, name, UInt32(RENAME_SWAP)) == 0 else { throw Rejection.changed }
                let parked = self.matches(temporary, identity: file.identity)
                    ? try? self.read(temporary, maximumBytes: max(1, file.data.count)) : nil
                guard let parked, parked.identity == file.identity, parked.data == file.data else {
                    if self.matches(name, identity: newIdentity) {
                        _ = renameatx_np(self.descriptor, temporary, self.descriptor, name, UInt32(RENAME_SWAP))
                    }
                    throw Rejection.changed
                }
                guard unlinkat(self.descriptor, temporary, 0) == 0 else { throw Rejection.io }
            } else {
                guard renameatx_np(self.descriptor, temporary, self.descriptor, name, UInt32(RENAME_EXCL)) == 0 else { throw Rejection.changed }
            }
        }

        static func validName(_ name: String) -> Bool {
            !name.isEmpty && name != "." && name != ".." && name.utf8.count <= Int(MAXNAMLEN)
                && !name.contains("/") && !name.contains("\0")
        }

        private static func openError() -> Rejection { errno == ENOENT ? .missing : .unsafe }
    }
}
