import Foundation
import Darwin

public final class SingleInstance {
    private let lockURL: URL
    private var descriptor: Int32 = -1

    public init(lockURL: URL) {
        self.lockURL = lockURL
    }

    deinit {
        release()
    }

    public func acquire(retries: Int = 20, interval: TimeInterval = 0.1) -> Bool {
        try? FileManager.default.createDirectory(
            at: lockURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard retries >= 0 else { return false }
        for attempt in 0...retries {
            let fd = open(lockURL.path, O_CREAT | O_RDWR, 0o600)
            if fd >= 0, flock(fd, LOCK_EX | LOCK_NB) == 0 {
                descriptor = fd
                return true
            }
            if fd >= 0 { close(fd) }
            if attempt < retries {
                Thread.sleep(forTimeInterval: interval)
            }
        }
        return false
    }

    public func release() {
        guard descriptor >= 0 else { return }
        flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
    }
}
