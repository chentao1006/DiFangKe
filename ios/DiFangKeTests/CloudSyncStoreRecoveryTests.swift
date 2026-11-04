import Foundation
import SQLite3
import XCTest

@testable import 地方客

final class CloudSyncStoreRecoveryTests: XCTestCase {
    func testRepairsKnownLegacyMismatchAndIsIdempotent() throws {
        let directory = try makeFixture(unsafeManualSelection: false)
        let storeURL = directory.appendingPathComponent("dfk_v5_stable.store")

        let first = try CloudSyncStoreRecovery.repairStoreIfNeeded(
            at: storeURL,
            supportDirectory: directory
        )
        XCTAssertEqual(first.normalizedTransportRows, 1)
        XCTAssertEqual(first.quarantinedManualSelectionRows, 1)
        let backupURL = try XCTUnwrap(first.backupURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupURL.path))
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM ZTRANSPORTRECORD WHERE Z_ENT = 8", at: storeURL), 0)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM ZTRANSPORTMANUALSELECTION WHERE Z_ENT = 7", at: storeURL), 0)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM ACHANGE WHERE ZENTITY = 8", at: storeURL), 0)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM Z_PRIMARYKEY WHERE Z_ENT = 8", at: storeURL), 0)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM ZTRANSPORTRECORD WHERE Z_ENT = 8", at: backupURL), 1)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM ZTRANSPORTMANUALSELECTION WHERE Z_ENT = 7", at: backupURL), 1)

        let second = try CloudSyncStoreRecovery.repairStoreIfNeeded(
            at: storeURL,
            supportDirectory: directory
        )
        XCTAssertFalse(second.didRepair)
        XCTAssertNil(second.backupURL)
    }

    func testUnknownMismatchFailsClosedWithoutPartialRepair() throws {
        let directory = try makeFixture(unsafeManualSelection: true)
        let storeURL = directory.appendingPathComponent("dfk_v5_stable.store")

        XCTAssertThrowsError(
            try CloudSyncStoreRecovery.repairStoreIfNeeded(
                at: storeURL,
                supportDirectory: directory
            )
        ) { error in
            guard case CloudSyncStoreRecovery.RecoveryError.unsafeShape = error else {
                return XCTFail("Expected unsafe-shape error, got \(error)")
            }
        }
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM ZTRANSPORTRECORD WHERE Z_ENT = 8", at: storeURL), 1)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM ZTRANSPORTMANUALSELECTION WHERE Z_ENT = 7", at: storeURL), 1)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM ACHANGE WHERE ZENTITY = 8", at: storeURL), 1)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("CloudSyncRecovery").path
            )
        )
    }

    private func makeFixture(unsafeManualSelection: Bool) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CloudSyncStoreRecoveryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let storeURL = directory.appendingPathComponent("dfk_v5_stable.store")
        var database: OpaquePointer?
        guard sqlite3_open(storeURL.path, &database) == SQLITE_OK, let database else {
            throw NSError(domain: "CloudSyncStoreRecoveryTests", code: 1)
        }
        defer { sqlite3_close(database) }
        try execute(
            """
            CREATE TABLE Z_PRIMARYKEY (Z_ENT INTEGER PRIMARY KEY, Z_NAME TEXT, Z_MAX INTEGER);
            CREATE TABLE ZTRANSPORTRECORD (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZRECORDID BLOB);
            CREATE TABLE ZTRANSPORTMANUALSELECTION (
                Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER,
                ZRECORDID BLOB, ZSTARTTIME REAL, ZENDTIME REAL,
                ZVEHICLETYPE TEXT, ZISDELETED INTEGER,
                ZSTARTLOCATIONOVERRIDE TEXT, ZENDLOCATIONOVERRIDE TEXT
            );
            CREATE TABLE ACHANGE (Z_PK INTEGER PRIMARY KEY, ZENTITY INTEGER, ZENTITYPK INTEGER);
            CREATE TABLE ANSCKRECORDMETADATA (
                Z_PK INTEGER PRIMARY KEY, ZENTITYID INTEGER, ZENTITYPK INTEGER
            );
            INSERT INTO Z_PRIMARYKEY VALUES (6, 'TransportManualSelection', 100);
            INSERT INTO Z_PRIMARYKEY VALUES (7, 'TransportRecord', 2844);
            INSERT INTO Z_PRIMARYKEY VALUES (8, 'TransportRecord', 2844);
            INSERT INTO ZTRANSPORTRECORD VALUES (2844, 8, 1, X'01');
            INSERT INTO ANSCKRECORDMETADATA VALUES (1, 7, 2844);
            INSERT INTO ACHANGE VALUES (1, 8, 2844);
            INSERT INTO ZTRANSPORTMANUALSELECTION VALUES
                (100, 6, 1, X'02', 1, 2, 'car', 0, NULL, NULL);
            INSERT INTO ZTRANSPORTMANUALSELECTION VALUES
                (2370, 7, 1, X'02', 1, 2, 'car', 0, NULL, NULL);
            """,
            in: database
        )
        if unsafeManualSelection {
            try execute(
                "UPDATE ZTRANSPORTMANUALSELECTION SET ZVEHICLETYPE = 'bus' WHERE Z_PK = 2370",
                in: database
            )
        }
        return directory
    }

    private func scalar(_ sql: String, at storeURL: URL) throws -> Int64 {
        var database: OpaquePointer?
        guard sqlite3_open_v2(storeURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let database else {
            throw NSError(domain: "CloudSyncStoreRecoveryTests", code: 2)
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw NSError(domain: "CloudSyncStoreRecoveryTests", code: 3)
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw NSError(domain: "CloudSyncStoreRecoveryTests", code: 4)
        }
        return sqlite3_column_int64(statement, 0)
    }

    private func execute(_ sql: String, in database: OpaquePointer) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "SQLite error"
            sqlite3_free(errorMessage)
            throw NSError(
                domain: "CloudSyncStoreRecoveryTests",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }
    }
}
