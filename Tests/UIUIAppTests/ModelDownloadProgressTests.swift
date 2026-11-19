import Foundation
import XCTest
@testable import UIUI

final class ModelDownloadProgressTests: XCTestCase {
    private final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Double] = []
        func add(_ value: Double?) { if let value { lock.withLock { values.append(value) } } }
        var all: [Double] { lock.withLock { values } }
    }

    /// The model download must report progress while bytes arrive, not just a spinner.
    /// The async download API never calls `didWriteData`, which once left this silent.
    func testDownloadReportsProgressWhileBytesArrive() async throws {
        let size = 12_000_000
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("uiui-progress-\(UUID().uuidString).bin")
        try Data(repeating: 7, count: size).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        let log = Log()
        let reporter = DownloadReporter(label: "Test", total: Int64(size), report: nil, fraction: { log.add($0) })
        let (file, _) = try await URLSession.shared.download(for: URLRequest(url: source), delegate: reporter.part(0))
        try? FileManager.default.removeItem(at: file)

        let values = log.all
        XCTAssertGreaterThan(values.count, 1, "expected several progress updates, got \(values)")
        XCTAssertEqual(try XCTUnwrap(values.last), 1, accuracy: 0.0001)
        XCTAssertEqual(values, values.sorted(), "progress went backwards: \(values)")
    }
}
