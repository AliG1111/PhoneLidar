import XCTest

/// Tolerant decoding of scan.json (C-17): older and newer files, missing fields and unknown kinds still open.
final class ScanRecordDecodingTests: XCTestCase {
    private func decode(_ json: String, folder: String? = "line_2026-11-10_101500") throws -> ScanRecord {
        let decoder = JSONDecoder.iso
        if let folder { decoder.userInfo[ScanRecord.folderNameInfoKey] = folder }
        return try decoder.decode(ScanRecord.self, from: Data(json.utf8))
    }

    func testEmptyObjectDecodesWithNeutralValues() throws {
        let record = try decode("{}")
        XCTAssertEqual(record.kind, .unknown)
        XCTAssertEqual(record.name, "line_2026-11-10_101500")
        XCTAssertEqual(record.folderName, "line_2026-11-10_101500")
        XCTAssertEqual(record.created, Date.distantPast)
        XCTAssertNil(record.primaryModel)
        XCTAssertTrue(record.files.isEmpty)
        XCTAssertTrue(record.summary.isEmpty)
        XCTAssertTrue(record.measurements.isEmpty)
    }

    func testMissingIDIsTheSameEveryTimeTheFileIsLoaded() throws {
        let first = try decode("{\"name\":\"A\"}")
        let second = try decode("{\"name\":\"A\"}")
        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(first.id, UUID.stable(from: "line_2026-11-10_101500"))
        let other = try decode("{\"name\":\"A\"}", folder: "line_2026-11-10_101501")
        XCTAssertNotEqual(first.id, other.id)
    }

    func testWithoutAFolderNameInTheDecoderTheFoldersAreEmpty() throws {
        let record = try decode("{\"kind\":\"room\"}", folder: nil)
        XCTAssertEqual(record.kind, .room)
        XCTAssertEqual(record.name, "")
        XCTAssertEqual(record.folderName, "")
    }

    func testUnknownKindBecomesUnknownAndKeepsTheOtherFields() throws {
        let json = """
        {"id":"5B3F0C2E-6E0A-4E57-9A53-3D1D2D0F8E11","kind":"hologram","name":"Press 4","created":"2023-11-14T22:13:20Z",
         "folderName":"hologram_2023-11-14_221320","primaryModel":"Model.usdz","files":["Model.usdz","Notes.txt"],
         "summary":["12 m²"],"measurements":[]}
        """
        let record = try decode(json)
        XCTAssertEqual(record.kind, .unknown)
        XCTAssertEqual(record.id, UUID(uuidString: "5B3F0C2E-6E0A-4E57-9A53-3D1D2D0F8E11"))
        XCTAssertEqual(record.name, "Press 4")
        XCTAssertEqual(record.created, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(record.folderName, "hologram_2023-11-14_221320")
        XCTAssertEqual(record.primaryModel, "Model.usdz")
        XCTAssertEqual(record.files, ["Model.usdz", "Notes.txt"])
        XCTAssertEqual(record.summary, ["12 m²"])
    }

    func testKnownKindsStillDecode() throws {
        for kind in [ScanKind.room, .mesh, .object, .line] {
            XCTAssertEqual(try decode("{\"kind\":\"\(kind.rawValue)\"}").kind, kind)
        }
    }

    func testAKindOfTheWrongTypeBecomesUnknown() throws {
        XCTAssertEqual(try decode("{\"kind\":123}").kind, .unknown)
        XCTAssertEqual(try decode("{\"kind\":null}").kind, .unknown)
    }

    func testScanKindDecodesFromABareString() throws {
        XCTAssertEqual(try JSONDecoder().decode(ScanKind.self, from: Data("\"line\"".utf8)), .line)
        XCTAssertEqual(try JSONDecoder().decode(ScanKind.self, from: Data("\"from-the-future\"".utf8)), .unknown)
    }

    func testUnknownKeysAreIgnored() throws {
        let record = try decode("{\"kind\":\"mesh\",\"name\":\"X\",\"colour\":\"red\",\"nested\":{\"a\":[1,2,3]}}")
        XCTAssertEqual(record.kind, .mesh)
        XCTAssertEqual(record.name, "X")
    }

    func testFieldsOfTheWrongTypeFallBackToDefaults() throws {
        let record = try decode("""
        {"name":5,"created":"not a date","files":"Mesh.obj","summary":{"a":1},"primaryModel":7,"kind":"object"}
        """)
        XCTAssertEqual(record.kind, .object)
        XCTAssertEqual(record.name, "line_2026-11-10_101500")
        XCTAssertEqual(record.created, Date.distantPast)
        XCTAssertTrue(record.files.isEmpty)
        XCTAssertTrue(record.summary.isEmpty)
        XCTAssertNil(record.primaryModel)
    }

    func testMeasurementsWithMissingFieldsGetNeutralValues() throws {
        let record = try decode("""
        {"kind":"mesh","measurements":[{"label":"Door","start":[1,2,3],"end":[4,5,6],"meters":5.5},{},{"label":"Half"}]}
        """)
        XCTAssertEqual(record.measurements.count, 3)
        XCTAssertEqual(record.measurements[0].label, "Door")
        XCTAssertEqual(record.measurements[0].start, [1, 2, 3])
        XCTAssertEqual(record.measurements[0].end, [4, 5, 6])
        XCTAssertEqual(record.measurements[0].meters, 5.5)
        XCTAssertEqual(record.measurements[1].label, "M")
        XCTAssertEqual(record.measurements[1].start, [0, 0, 0])
        XCTAssertEqual(record.measurements[1].end, [0, 0, 0])
        XCTAssertEqual(record.measurements[1].meters, 0)
        XCTAssertEqual(record.measurements[2].label, "Half")
        XCTAssertEqual(record.measurements[2].meters, 0)
    }

    func testFileThatIsNotAnObjectStillFailsToDecode() {
        XCTAssertThrowsError(try decode("[1, 2, 3]"))
        XCTAssertThrowsError(try decode("not json"))
        XCTAssertThrowsError(try decode(""))
    }

    /// D-4: a kind written by a newer build is kept verbatim when this build saves the record again (rename),
    /// so the newer build still finds its kind; this build reads it as `.unknown`.
    func testUnknownKindIsWrittenBackUnchanged() throws {
        var record = try decode("{\"kind\":\"hologram\",\"name\":\"X\"}")
        XCTAssertEqual(record.kind, .unknown)
        record.name = "Renamed"
        let data = try JSONEncoder.pretty.encode(record)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["kind"] as? String, "hologram")
        XCTAssertEqual(json["name"] as? String, "Renamed")
        XCTAssertEqual(try JSONDecoder.iso.decode(ScanRecord.self, from: data).kind, .unknown)
    }

    func testKnownKindIsWrittenWithItsOwnRawValue() throws {
        let record = try decode("{\"kind\":\"line\",\"name\":\"X\"}")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: try JSONEncoder.pretty.encode(record)) as? [String: Any])
        XCTAssertEqual(json["kind"] as? String, "line")
    }

    func testStableIDsRepeatAndDiffer() {
        XCTAssertEqual(UUID.stable(from: "abc"), UUID.stable(from: "abc"))
        XCTAssertNotEqual(UUID.stable(from: "abc"), UUID.stable(from: "abd"))
        XCTAssertNotEqual(UUID.stable(from: ""), UUID.stable(from: "a"))
        XCTAssertEqual(UUID.stable(from: "").uuidString.count, 36)
    }
}

final class ScanErrorTests: XCTestCase {
    func testDiskFullIsRecognisedInEveryForm() {
        XCTAssertTrue(ScanError.isDiskFull(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)))
        XCTAssertTrue(ScanError.isDiskFull(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))))
        let wrapped = NSError(domain: "Wrapper", code: 1,
                              userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))])
        XCTAssertTrue(ScanError.isDiskFull(wrapped))
        XCTAssertFalse(ScanError.isDiskFull(NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))))
        XCTAssertFalse(ScanError.isDiskFull(NSError(domain: "Other", code: Int(ENOSPC))))
    }

    func testMessageForDiskFullIsPlainLanguage() {
        let message = ScanError.message(for: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC)))
        XCTAssertEqual(message, ScanError.diskFull.errorDescription)
        XCTAssertTrue(message.contains("Not enough free space"))
    }

    func testMessageForOtherErrorsIsTheirOwn() {
        let error = NSError(domain: "Test", code: 7, userInfo: [NSLocalizedDescriptionKey: "Something broke."])
        XCTAssertEqual(ScanError.message(for: error), "Something broke.")
        XCTAssertNotNil(ScanError.diskFull.errorDescription)
    }
}

/// Listing, deleting and describing scan folders. The store works in the Documents/Scans folder of the test
/// process; every folder made here has a unique name and is removed when the test ends.
final class ScanStoreFolderTests: XCTestCase {
    /// A new folder with a unique name inside the store's root, removed when the test finishes.
    @MainActor
    private func makeScanFolder(in store: ScanStore, prefix: String = "zz-unit-test") throws -> (name: String, url: URL) {
        let name = "\(prefix)-\(UUID().uuidString)"
        let url = store.root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return (name, url)
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    // MARK: - Incomplete scans (C-12)

    @MainActor
    func testFolderWithoutScanJSONIsListedAsIncomplete() throws {
        let store = ScanStore()
        let folder = try makeScanFolder(in: store)
        try write("0123456789", to: folder.url.appendingPathComponent("Partial.bin"))
        try write("12345", to: folder.url.appendingPathComponent("Images/IMG_0001.heic"))
        try write("", to: folder.url.appendingPathComponent(".recording-in-progress"))      // hidden: not counted
        store.reload()

        let entry = try XCTUnwrap(store.incomplete.first { $0.folderName == folder.name })
        XCTAssertEqual(entry.fileCount, 2)
        XCTAssertEqual(entry.bytes, 15)
        XCTAssertEqual(entry.id, folder.name)
        XCTAssertEqual(store.incompleteScan(named: folder.name)?.folderName, folder.name)
        XCTAssertLessThan(abs(entry.date.timeIntervalSinceNow), 600)
        XCTAssertFalse(store.scans.contains { $0.folderName == folder.name })
    }

    @MainActor
    func testEmptyFolderIsListedAsIncompleteWithNoFiles() throws {
        let store = ScanStore()
        let folder = try makeScanFolder(in: store)
        store.reload()
        let entry = try XCTUnwrap(store.incomplete.first { $0.folderName == folder.name })
        XCTAssertEqual(entry.fileCount, 0)
        XCTAssertEqual(entry.bytes, 0)
    }

    @MainActor
    func testScanJSONMakesTheFolderAScanEvenWithAnUnknownKind() throws {
        let store = ScanStore()
        let folder = try makeScanFolder(in: store)
        try write("{\"kind\":\"hologram\",\"name\":\"Future scan\"}", to: folder.url.appendingPathComponent("scan.json"))
        store.reload()

        let record = try XCTUnwrap(store.scans.first { $0.folderName == folder.name })
        XCTAssertEqual(record.kind, .unknown)
        XCTAssertEqual(record.name, "Future scan")
        XCTAssertGreaterThan(record.created, Date.distantPast)      // taken from the folder's date
        XCTAssertLessThan(abs(record.created.timeIntervalSinceNow), 600)
        XCTAssertEqual(store.record(id: record.id)?.folderName, folder.name)
        XCTAssertFalse(store.incomplete.contains { $0.folderName == folder.name })
    }

    @MainActor
    func testScanJSONWithMissingFieldsStillOpens() throws {
        let store = ScanStore()
        let folder = try makeScanFolder(in: store)
        try write("{}", to: folder.url.appendingPathComponent("scan.json"))
        store.reload()
        let record = try XCTUnwrap(store.scans.first { $0.folderName == folder.name })
        XCTAssertEqual(record.name, folder.name)
        XCTAssertEqual(record.id, UUID.stable(from: folder.name))
        XCTAssertFalse(store.incomplete.contains { $0.folderName == folder.name })
    }

    @MainActor
    func testUnreadableScanJSONLeavesTheFolderIncomplete() throws {
        let store = ScanStore()
        let folder = try makeScanFolder(in: store)
        try write("this is not json", to: folder.url.appendingPathComponent("scan.json"))
        store.reload()
        XCTAssertTrue(store.incomplete.contains { $0.folderName == folder.name })
        XCTAssertFalse(store.scans.contains { $0.folderName == folder.name })
        try write("[]", to: folder.url.appendingPathComponent("scan.json"))
        store.reload()
        XCTAssertTrue(store.incomplete.contains { $0.folderName == folder.name })
    }

    @MainActor
    func testPlainFilesInTheScansFolderAreNotListed() throws {
        let store = ScanStore()
        let name = "zz-unit-test-\(UUID().uuidString).txt"
        let url = store.root.appendingPathComponent(name)
        try write("x", to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        store.reload()
        XCTAssertFalse(store.incomplete.contains { $0.folderName == name })
        XCTAssertFalse(store.scans.contains { $0.folderName == name })
    }

    // MARK: - Deleting

    @MainActor
    func testDeleteIncompleteRemovesOnlyFoldersWithoutAScanRecord() throws {
        let store = ScanStore()
        let incomplete = try makeScanFolder(in: store)
        try write("data", to: incomplete.url.appendingPathComponent("Partial.bin"))
        let complete = try makeScanFolder(in: store)
        try write("{}", to: complete.url.appendingPathComponent("scan.json"))
        store.reload()

        XCTAssertTrue(store.deleteIncomplete(folderName: incomplete.name))
        XCTAssertFalse(FileManager.default.fileExists(atPath: incomplete.url.path))
        XCTAssertFalse(store.incomplete.contains { $0.folderName == incomplete.name })

        XCTAssertFalse(store.deleteIncomplete(folderName: complete.name))
        XCTAssertTrue(FileManager.default.fileExists(atPath: complete.url.path))
        XCTAssertTrue(store.scans.contains { $0.folderName == complete.name })
    }

    @MainActor
    func testDeleteIncompleteRefusesNamesThatLeaveTheScansFolder() {
        let store = ScanStore()
        for name in ["", ".", "..", "../x", ".hidden", "a/b", "a\\b", "x/../.."] {
            XCTAssertFalse(store.deleteIncomplete(folderName: name), "name \"\(name)\"")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.root.path))
    }

    @MainActor
    func testDiscardIsDeleteIncomplete() throws {
        let store = ScanStore()
        let incomplete = try makeScanFolder(in: store)
        let complete = try makeScanFolder(in: store)
        try write("{}", to: complete.url.appendingPathComponent("scan.json"))
        store.discard(folderName: incomplete.name)
        store.discard(folderName: complete.name)
        XCTAssertFalse(FileManager.default.fileExists(atPath: incomplete.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: complete.url.path))
    }

    // MARK: - Saving

    @MainActor
    func testSaveListsTheFilesAndDeleteRemovesTheFolder() throws {
        let store = ScanStore()
        let made = try store.newFolder(kind: .line)
        addTeardownBlock { try? FileManager.default.removeItem(at: made.url) }
        XCTAssertTrue(made.name.hasPrefix("line_"))
        try write("a", to: made.url.appendingPathComponent("Recording.json"))
        try write("b", to: made.url.appendingPathComponent("Depth.bin"))
        let record = ScanRecord(id: UUID(), kind: .line, name: "Test line", created: Date(), folderName: made.name,
                                primaryModel: nil, files: ["ignored.txt"], summary: ["2 frames"], measurements: [])
        try store.save(record)

        let saved = try XCTUnwrap(store.record(id: record.id))
        XCTAssertEqual(saved.files, ["Depth.bin", "Recording.json"])      // taken from the folder, scan.json left out
        XCTAssertEqual(saved.summary, ["2 frames"])
        XCTAssertEqual(store.fileURL("Depth.bin", in: saved).lastPathComponent, "Depth.bin")
        XCTAssertFalse(store.incomplete.contains { $0.folderName == made.name })

        XCTAssertTrue(store.delete(saved))
        XCTAssertFalse(FileManager.default.fileExists(atPath: made.url.path))
        XCTAssertNil(store.record(id: record.id))
    }

    @MainActor
    func testDeleteRefusesARecordWhoseScanJSONBelongsToAnotherScan() throws {
        let store = ScanStore()
        let made = try store.newFolder(kind: .room)
        addTeardownBlock { try? FileManager.default.removeItem(at: made.url) }
        let record = ScanRecord(id: UUID(), kind: .room, name: "Real", created: Date(), folderName: made.name)
        try store.save(record)
        let impostor = ScanRecord(id: UUID(), kind: .room, name: "Impostor", created: Date(), folderName: made.name)
        XCTAssertFalse(store.delete(impostor))
        XCTAssertTrue(FileManager.default.fileExists(atPath: made.url.path))
    }

    @MainActor
    func testNewFoldersAreUniqueEvenInTheSameSecond() throws {
        let store = ScanStore()
        let first = try store.newFolder(kind: .mesh)
        let second = try store.newFolder(kind: .mesh)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: first.url)
            try? FileManager.default.removeItem(at: second.url)
        }
        XCTAssertNotEqual(first.name, second.name)
        XCTAssertTrue(first.name.hasPrefix("mesh_"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.url.path))
    }

    // MARK: - Folder contents

    @MainActor
    func testEntriesListFilesAndFoldersAndSkipTheCheckpointCache() throws {
        let store = ScanStore()
        let folder = try makeScanFolder(in: store)
        try write("1234", to: folder.url.appendingPathComponent("b.txt"))
        try write("12", to: folder.url.appendingPathComponent("a.txt"))
        try write("123", to: folder.url.appendingPathComponent("Images/one.heic"))
        try write("12345", to: folder.url.appendingPathComponent("Images/two.heic"))
        try write("cache", to: folder.url.appendingPathComponent("Checkpoint/cache.bin"))
        try FileManager.default.createDirectory(at: folder.url.appendingPathComponent("Empty"),
                                                withIntermediateDirectories: true)
        try write("", to: folder.url.appendingPathComponent(".hidden"))

        let entries = store.entries(inFolderNamed: folder.name)
        XCTAssertEqual(entries.map(\.name), ["a.txt", "b.txt", "Images"])
        XCTAssertEqual(entries.map(\.isDirectory), [false, false, true])
        XCTAssertEqual(entries[0].bytes, 2)
        XCTAssertEqual(entries[1].bytes, 4)
        XCTAssertEqual(entries[2].bytes, 8)
        XCTAssertEqual(entries[2].urls.map(\.lastPathComponent), ["one.heic", "two.heic"])
        XCTAssertEqual(entries[0].urls.count, 1)
    }

    func testSizesOfListedFilesAndTheWholeFolder() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("zz-sizes-\(UUID().uuidString)",
                                                                                isDirectory: true)
        let url = base.appendingPathComponent("scan", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        try write("1234567", to: url.appendingPathComponent("Depth.bin"))
        try write("", to: url.appendingPathComponent("Empty.csv"))
        try write("123", to: url.appendingPathComponent("scan.json"))
        try write("12345", to: url.appendingPathComponent("Images/one.heic"))
        try write("cache", to: url.appendingPathComponent("Checkpoint/cache.bin"))
        try write("hidden", to: url.appendingPathComponent(".recording-in-progress"))   // hidden: not counted
        try FileManager.default.createDirectory(at: url.appendingPathComponent("Folder.bin"),
                                                withIntermediateDirectories: true)
        try write("outside the scan", to: base.appendingPathComponent("Depth.bin"))          // "../Depth.bin"

        let names = ["Depth.bin", "Empty.csv", "Missing.mov", "Folder.bin", "../Depth.bin", "Images/one.heic", ""]
        let sizes = ScanStore.sizes(of: names, in: url)
        XCTAssertEqual(sizes.files, ["Depth.bin": 7, "Empty.csv": 0])
        XCTAssertEqual(sizes.total, 7 + 0 + 3 + 5 + 5)
        XCTAssertEqual(sizes.listedTotal(names), 7)
        XCTAssertEqual(sizes.listedTotal([]), 0)
    }

    func testSizesOfAMissingFolderAreZero() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("zz-none-\(UUID().uuidString)")
        XCTAssertEqual(ScanStore.sizes(of: ["Depth.bin"], in: url), ScanSizes())
    }

    @MainActor
    func testEntriesOfAnUnknownOrInvalidFolderAreEmpty() {
        let store = ScanStore()
        XCTAssertTrue(store.entries(inFolderNamed: "zz-unit-test-does-not-exist").isEmpty)
        XCTAssertTrue(store.entries(inFolderNamed: "../").isEmpty)
        XCTAssertTrue(store.entries(inFolderNamed: "").isEmpty)
    }
}
