import XCTest
@testable import CortexSentinelBar

final class LineStatusFileCacheTests: XCTestCase {
    private let fileManager = FileManager.default
    private var root: URL!
    private let fixedModificationDate = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUpWithError() throws {
        root = fileManager.temporaryDirectory
            .appendingPathComponent("line-status-cache-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fileManager.removeItem(at: root)
    }

    func testUnchangedModificationDateAndSizeReuseDecodedLine() throws {
        let cache = LineStatusFileCache()
        let first = statusJSON(slug: "alpha")
        let replacement = statusJSON(slug: "omega")
        XCTAssertEqual(first.count, replacement.count)

        let url = try write(name: "codex-babysitter-alpha.status.json", first, modificationDate: fixedModificationDate)
        XCTAssertEqual(
            SentinelFileReader.readLines(in: root, cache: cache).first?.slug,
            "alpha"
        )
        XCTAssertEqual(cache.parseCount, 1)

        try write(name: url.lastPathComponent, replacement, modificationDate: fixedModificationDate)
        let cached = SentinelFileReader.readLines(in: root, cache: cache)
        XCTAssertEqual(cached.first?.slug, "alpha")
        XCTAssertEqual(cache.parseCount, 1)
    }

    func testModificationDateChangeReloadsSameSizedLine() throws {
        let cache = LineStatusFileCache()
        let first = statusJSON(slug: "alpha")
        let replacement = statusJSON(slug: "omega")
        XCTAssertEqual(first.count, replacement.count)

        try write(name: "codex-babysitter-alpha.status.json", first, modificationDate: fixedModificationDate)
        XCTAssertEqual(
            SentinelFileReader.readLines(in: root, cache: cache).first?.slug,
            "alpha"
        )

        try write(
            name: "codex-babysitter-alpha.status.json",
            replacement,
            modificationDate: fixedModificationDate.addingTimeInterval(1)
        )
        let reloaded = SentinelFileReader.readLines(in: root, cache: cache)
        XCTAssertEqual(reloaded.first?.slug, "omega")
        XCTAssertEqual(cache.parseCount, 2)
    }

    func testSizeChangeReloadsLineWithSameModificationDate() throws {
        let cache = LineStatusFileCache()
        try write(
            name: "codex-babysitter-alpha.status.json",
            statusJSON(slug: "alpha"),
            modificationDate: fixedModificationDate
        )
        XCTAssertEqual(
            SentinelFileReader.readLines(in: root, cache: cache).first?.slug,
            "alpha"
        )

        try write(
            name: "codex-babysitter-alpha.status.json",
            statusJSON(slug: "longer-slug"),
            modificationDate: fixedModificationDate
        )
        let reloaded = SentinelFileReader.readLines(in: root, cache: cache)
        XCTAssertEqual(reloaded.first?.slug, "longer-slug")
        XCTAssertEqual(cache.parseCount, 2)
    }

    func testInPlaceRewriteIsSeenEvenIfDirectoryListingStays() throws {
        let cache = LineStatusFileCache()
        try write(
            name: "codex-babysitter-alpha.status.json",
            statusJSON(slug: "alpha", state: "running"),
            modificationDate: fixedModificationDate
        )
        XCTAssertEqual(
            SentinelFileReader.readLines(in: root, cache: cache).first?.state,
            .running
        )

        try write(
            name: "codex-babysitter-alpha.status.json",
            statusJSON(slug: "alpha", state: "done"),
            modificationDate: fixedModificationDate.addingTimeInterval(2)
        )
        let reloaded = SentinelFileReader.readLines(in: root, cache: cache)
        XCTAssertEqual(reloaded.first?.state, .done)
        XCTAssertEqual(cache.parseCount, 2)
    }

    func testRemovedFileDropsFromResultsAndCache() throws {
        let cache = LineStatusFileCache()
        let url = try write(
            name: "codex-babysitter-alpha.status.json",
            statusJSON(slug: "alpha"),
            modificationDate: fixedModificationDate
        )
        XCTAssertEqual(SentinelFileReader.readLines(in: root, cache: cache).count, 1)

        try fileManager.removeItem(at: url)
        XCTAssertEqual(SentinelFileReader.readLines(in: root, cache: cache), [])

        try write(
            name: "codex-babysitter-beta.status.json",
            statusJSON(slug: "beta"),
            modificationDate: fixedModificationDate
        )
        XCTAssertEqual(
            SentinelFileReader.readLines(in: root, cache: cache).first?.slug,
            "beta"
        )
        XCTAssertEqual(cache.parseCount, 2)
    }

    @discardableResult
    private func write(
        name: String,
        _ data: Data,
        modificationDate: Date
    ) throws -> URL {
        let url = root.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        try fileManager.setAttributes(
            [.modificationDate: modificationDate],
            ofItemAtPath: url.path
        )
        return url
    }

    private func statusJSON(slug: String, state: String = "running") -> Data {
        Data(
            """
            {"slug":"\(slug)","state":"\(state)"}
            """.utf8
        )
    }
}
