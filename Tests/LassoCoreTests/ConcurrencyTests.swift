import XCTest
@testable import LassoCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// SPE-550: several Agents each spawn their own Hub, all reading one Store the
// Conductor writes. These assert the multi-client guarantees at the Store level:
// concurrent readers, no hard-consume, and independent per-reader after_id.
final class ConcurrencyTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("lasso-conc-" + UUID().uuidString, isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private var png: Data { Data([0x89, 0x50, 0x4E, 0x47]) }

    private func pngCount() throws -> Int {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return files.filter { $0.hasSuffix(".png") }.count
    }

    func testWriterUsesWAL() throws {
        let writer = try Store(directory: dir)
        try writer.insert(imagePNG: png, context: CaptureContext(source: .none), note: nil)
        XCTAssertEqual(try writer.journalMode(), "wal")
    }

    func testReaderCannotWriteAndLeavesNoTrace() throws {
        let writer = try Store(directory: dir)
        let written = try writer.insert(imagePNG: png, context: CaptureContext(source: .none), note: nil)
        let pngBefore = try pngCount()

        let reader = try Store(directory: dir, readOnly: true)
        // query_only pins the reader connection: a write must fail...
        XCTAssertThrowsError(try reader.insert(imagePNG: png, context: CaptureContext(source: .none), note: nil))
        // ...and leave nothing behind: same latest id, no orphan PNG.
        XCTAssertEqual(try Store(directory: dir, readOnly: true).latest()?.id, written.id)
        XCTAssertEqual(try pngCount(), pngBefore)
    }

    // Negative control: a reader holds an open read snapshot while a separate
    // writer connection commits. Under WAL the writer proceeds; if this ever
    // regressed to rollback-journal locking the writer would hit SQLITE_BUSY
    // within the short 300ms busy timeout and this test would fail fast.
    func testReaderSnapshotDoesNotBlockConcurrentWriter() throws {
        let writer = try Store(directory: dir)
        let bootstrap = try writer.insert(imagePNG: png, context: CaptureContext(source: .none), note: nil)
        let reader = try Store(directory: dir, readOnly: true, busyTimeoutMs: 300)
        let writerConn = try Store(directory: dir, busyTimeoutMs: 300)

        let readerHolding = DispatchSemaphore(value: 0)
        let writerFinished = DispatchSemaphore(value: 0)
        let done = expectation(description: "reader transaction complete")

        var snapshotId: Int64?
        var afterCommitId: Int64?
        var readError: Error?

        DispatchQueue.global().async {
            do {
                try reader.readTransaction {
                    snapshotId = try reader.latest()?.id   // acquire the snapshot
                    readerHolding.signal()
                    writerFinished.wait()                  // hold it while writer commits
                    _ = try reader.latest()                // still readable inside the txn
                }
                afterCommitId = try reader.latest()?.id    // a fresh read sees the writes
            } catch {
                readError = error
            }
            done.fulfill()
        }

        readerHolding.wait()
        var writeError: Error?
        do {
            for _ in 0..<3 {
                try writerConn.insert(imagePNG: png, context: CaptureContext(source: .none), note: nil)
            }
        } catch {
            writeError = error
        }
        writerFinished.signal()
        wait(for: [done], timeout: 5)

        XCTAssertNil(writeError, "writer blocked while a reader held a snapshot — WAL not active?")
        XCTAssertNil(readError)
        XCTAssertEqual(snapshotId, bootstrap.id, "snapshot should be stable during the writer's commits")
        XCTAssertEqual(afterCommitId, bootstrap.id + 3, "a fresh read should see the committed writes")
    }

    func testReaderOpensWalDbAfterWriterClosed() throws {
        var writer: Store? = try Store(directory: dir)
        let written = try writer!.insert(imagePNG: png, context: CaptureContext(source: .none), note: nil)
        XCTAssertEqual(try writer!.journalMode(), "wal")
        writer = nil // close the writer connection (checkpoints WAL)

        // A fresh read-only Hub can still open and read the WAL-mode Store.
        let reader = try Store(directory: dir, readOnly: true)
        XCTAssertEqual(try reader.latest()?.id, written.id)
    }

    func testConcurrentReadersWithLiveWriter() throws {
        // Create the DB + table first so readers have something to open.
        let bootstrap = try Store(directory: dir)
        try bootstrap.insert(imagePNG: png, context: CaptureContext(source: .none), note: nil)

        let rounds = 40
        let lock = NSLock()
        var errors: [String] = []
        func record(_ e: Error) { lock.lock(); errors.append("\(e)"); lock.unlock() }

        // Lane 0 writes on its own connection; lanes 1...7 read on their own.
        // WAL + busy_timeout must let this run without SQLITE_BUSY failures.
        DispatchQueue.concurrentPerform(iterations: 8) { lane in
            do {
                let store = try Store(directory: dir, readOnly: lane != 0)
                for _ in 0..<rounds {
                    if lane == 0 {
                        try store.insert(imagePNG: png, context: CaptureContext(source: .none), note: nil)
                    } else {
                        _ = try store.latest()
                    }
                }
            } catch {
                record(error)
            }
        }

        XCTAssertEqual(errors, [], "concurrent WAL access raised errors")
        let reader = try Store(directory: dir, readOnly: true)
        XCTAssertEqual(try reader.latestId(), Int64(rounds + 1)) // bootstrap + writer lane
    }

    func testTwoReadersSeeTheSameLatest() throws {
        let writer = try Store(directory: dir)
        let written = try writer.insert(imagePNG: png, context: CaptureContext(source: .ocr, text: "hi"), note: nil)

        let readerA = try Store(directory: dir, readOnly: true)
        let readerB = try Store(directory: dir, readOnly: true)
        XCTAssertEqual(try readerA.latest()?.id, written.id)
        XCTAssertEqual(try readerB.latest()?.id, written.id)
    }

    func testNoHardConsume() throws {
        let writer = try Store(directory: dir)
        let written = try writer.insert(imagePNG: png, context: CaptureContext(source: .none), note: nil)

        let reader = try Store(directory: dir, readOnly: true)
        // Reading does not remove the Capture: repeated reads and a second
        // reader all still see it.
        XCTAssertEqual(try reader.latest()?.id, written.id)
        XCTAssertEqual(try reader.latest()?.id, written.id)
        let other = try Store(directory: dir, readOnly: true)
        XCTAssertEqual(try other.latest()?.id, written.id)
    }

    func testPerReaderAfterIdIsIndependent() throws {
        let writer = try Store(directory: dir)
        let first = try writer.insert(imagePNG: png, context: CaptureContext(source: .none), note: nil)

        let caughtUp = try Store(directory: dir, readOnly: true)   // has seen `first`
        let fresh = try Store(directory: dir, readOnly: true)      // has seen nothing

        // Reader that already saw `first` gets nothing new; a fresh reader gets it.
        XCTAssertNil(try caughtUp.latest(afterId: first.id))
        XCTAssertEqual(try fresh.latest(afterId: nil)?.id, first.id)

        // A new Capture lands; the caught-up reader now sees exactly the new one.
        let second = try writer.insert(imagePNG: png, context: CaptureContext(source: .none), note: nil)
        XCTAssertEqual(try caughtUp.latest(afterId: first.id)?.id, second.id)
    }

    func testReaderSeesWritesCommittedAfterItOpened() throws {
        let writer = try Store(directory: dir)
        try writer.insert(imagePNG: png, context: CaptureContext(source: .none), note: nil)
        let reader = try Store(directory: dir, readOnly: true)
        // A write committed after the reader opened is visible on the next query.
        let second = try writer.insert(imagePNG: png, context: CaptureContext(source: .none), note: nil)
        XCTAssertEqual(try reader.latest()?.id, second.id)
    }

    func testCaptureStateMutationWaitsForCrossProcessReadLock() throws {
        let writer = try Store(directory: dir)
        let capture = try writer.insert(
            imagePNG: png,
            context: CaptureContext(source: .none),
            note: nil
        )
        let lockFD = open(
            dir.appendingPathComponent(".capture-lifecycle.lock").path,
            O_RDWR | O_CLOEXEC
        )
        XCTAssertGreaterThanOrEqual(lockFD, 0)
        guard lockFD >= 0 else { return }
        defer { close(lockFD) }
        XCTAssertEqual(flock(lockFD, LOCK_SH), 0)

        let writerStarted = DispatchSemaphore(value: 0)
        let writerFinished = DispatchSemaphore(value: 0)
        let errorsLock = NSLock()
        var errors: [Error] = []

        DispatchQueue.global().async {
            writerStarted.signal()
            do {
                try writer.moveToTrash(id: capture.id)
            } catch {
                errorsLock.lock(); errors.append(error); errorsLock.unlock()
            }
            writerFinished.signal()
        }
        XCTAssertEqual(writerStarted.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(
            writerFinished.wait(timeout: .now() + 0.15),
            .timedOut,
            "moving a Capture must wait until an in-flight read has finished"
        )

        XCTAssertEqual(flock(lockFD, LOCK_UN), 0)
        XCTAssertEqual(writerFinished.wait(timeout: .now() + 1), .success)
        errorsLock.lock(); let capturedErrors = errors; errorsLock.unlock()
        XCTAssertTrue(capturedErrors.isEmpty, "concurrent lifecycle operations failed: \(capturedErrors)")
        XCTAssertEqual(try writer.capture(id: capture.id)?.libraryState, .recentlyDeleted)
    }

    func testCaptureStateMutationTimesOutInsteadOfBlockingForever() throws {
        let writer = try Store(directory: dir)
        let capture = try writer.insert(
            imagePNG: png,
            context: CaptureContext(source: .none),
            note: nil
        )
        let lockFD = open(
            dir.appendingPathComponent(".capture-lifecycle.lock").path,
            O_RDWR | O_CLOEXEC
        )
        XCTAssertGreaterThanOrEqual(lockFD, 0)
        guard lockFD >= 0 else { return }
        defer { close(lockFD) }
        XCTAssertEqual(flock(lockFD, LOCK_SH), 0)

        let finished = DispatchSemaphore(value: 0)
        let resultLock = NSLock()
        var result: Result<Void, Error>?
        DispatchQueue.global().async {
            let attempt = Result { try writer.moveToTrash(id: capture.id) }
            resultLock.lock(); result = attempt; resultLock.unlock()
            finished.signal()
        }

        XCTAssertEqual(finished.wait(timeout: .now() + 3), .success)
        resultLock.lock(); let capturedResult = result; resultLock.unlock()
        guard case .failure(let error) = capturedResult else {
            XCTFail("mutation unexpectedly acquired a permanently held lifecycle lock")
            return
        }
        XCTAssertTrue(String(describing: error).contains("busy for too long"))
        XCTAssertEqual(try writer.capture(id: capture.id)?.libraryState, .recent)
        XCTAssertEqual(flock(lockFD, LOCK_UN), 0)
    }
}
