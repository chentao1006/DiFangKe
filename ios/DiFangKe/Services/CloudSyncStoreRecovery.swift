import Foundation
import SQLite3

/// Repairs the released core store before SwiftData installs its CloudKit exporter.
///
/// Some upgraded stores contain rows whose internal Core Data entity number no
/// longer matches the entity number retained by CloudKit metadata. Core Data's
/// exporter throws while enumerating those rows, so it cannot skip the offending
/// object itself. This recovery is intentionally limited to the two shapes that
/// can be proved without interpreting user data:
///
/// - a transport row has a stale entity number but the same primary key already
///   has a CloudKit mapping for the canonical TransportRecord entity;
/// - a manual-selection row has the wrong entity number and an byte-for-byte
///   equivalent row under the canonical manual-selection entity.
///
/// A SQLite backup is created while the source is write-locked, before any row
/// changes. Unknown or partially matching shapes fail closed.
enum CloudSyncStoreRecovery {
    struct Report: Sendable {
        let normalizedTransportRows: Int
        let quarantinedManualSelectionRows: Int
        let backupURL: URL?

        var didRepair: Bool {
            normalizedTransportRows > 0 || quarantinedManualSelectionRows > 0
        }
    }

    enum RecoveryError: LocalizedError {
        case appGroupUnavailable
        case sqlite(String)
        case unsafeShape(String)

        var errorDescription: String? {
            switch self {
            case .appGroupUnavailable:
                return "无法访问足迹数据库目录。"
            case .sqlite(let detail):
                return "足迹数据库检查失败：\(detail)"
            case .unsafeShape(let detail):
                return "发现未知的同步数据库异常，已保留原数据：\(detail)"
            }
        }
    }

    static func repairIfNeeded(appGroupID: String) throws -> Report {
        guard !appGroupID.isEmpty,
              let groupURL = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: appGroupID
              ) else {
            throw RecoveryError.appGroupUnavailable
        }
        let supportURL = groupURL.appendingPathComponent("Library/Application Support", isDirectory: true)
        return try repairStoreIfNeeded(
            at: supportURL.appendingPathComponent("dfk_v5_stable.store"),
            supportDirectory: supportURL
        )
    }

    /// Internal entry point also used to validate real previous-version store copies.
    static func repairStoreIfNeeded(at storeURL: URL, supportDirectory: URL) throws -> Report {
        guard FileManager.default.fileExists(atPath: storeURL.path) else {
            return Report(normalizedTransportRows: 0, quarantinedManualSelectionRows: 0, backupURL: nil)
        }

        var database: OpaquePointer?
        let openResult = sqlite3_open_v2(
            storeURL.path,
            &database,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard openResult == SQLITE_OK, let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "无法打开数据库"
            if let database { sqlite3_close(database) }
            throw RecoveryError.sqlite(message)
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 15_000)

        var transactionStarted = false
        do {
            try execute("BEGIN IMMEDIATE", in: database)
            transactionStarted = true

            guard try hasRequiredTables(in: database) else {
                try execute("ROLLBACK", in: database)
                transactionStarted = false
                return Report(normalizedTransportRows: 0, quarantinedManualSelectionRows: 0, backupURL: nil)
            }

            let transportPlan = try inspectTransportRepair(in: database)
            let manualPlan = try inspectManualSelectionRepair(in: database)
            guard !transportPlan.rowIDs.isEmpty || !manualPlan.rowIDs.isEmpty else {
                try execute("ROLLBACK", in: database)
                transactionStarted = false
                return Report(normalizedTransportRows: 0, quarantinedManualSelectionRows: 0, backupURL: nil)
            }

            let backupURL = try createBackup(
                sourceStoreURL: storeURL,
                supportDirectory: supportDirectory
            )

            for staleEntityID in transportPlan.staleEntityIDs {
                try execute(
                    "UPDATE ZTRANSPORTRECORD SET Z_ENT = ? WHERE Z_ENT = ?",
                    integers: [transportPlan.canonicalEntityID, staleEntityID],
                    in: database
                )
                try execute(
                    "UPDATE ACHANGE SET ZENTITY = ? WHERE ZENTITY = ?",
                    integers: [transportPlan.canonicalEntityID, staleEntityID],
                    in: database
                )
                try execute(
                    "UPDATE Z_PRIMARYKEY SET Z_MAX = MAX(Z_MAX, " +
                    "COALESCE((SELECT Z_MAX FROM Z_PRIMARYKEY WHERE Z_ENT = ?), Z_MAX)) " +
                    "WHERE Z_ENT = ?",
                    integers: [staleEntityID, transportPlan.canonicalEntityID],
                    in: database
                )
                try execute(
                    "DELETE FROM Z_PRIMARYKEY WHERE Z_ENT = ? AND Z_NAME = 'TransportRecord'",
                    integers: [staleEntityID],
                    in: database
                )
            }

            for rowID in manualPlan.rowIDs {
                try execute(
                    "DELETE FROM ZTRANSPORTMANUALSELECTION WHERE Z_PK = ? AND Z_ENT <> ?",
                    integers: [rowID, manualPlan.canonicalEntityID],
                    in: database
                )
            }

            let remainingStaleTransports = try scalarInt(
                "SELECT COUNT(*) FROM ZTRANSPORTRECORD WHERE Z_ENT <> ?",
                integers: [transportPlan.canonicalEntityID],
                in: database
            )
            let remainingStaleManualSelections = try scalarInt(
                "SELECT COUNT(*) FROM ZTRANSPORTMANUALSELECTION WHERE Z_ENT <> ?",
                integers: [manualPlan.canonicalEntityID],
                in: database
            )
            guard remainingStaleTransports == 0, remainingStaleManualSelections == 0 else {
                throw RecoveryError.unsafeShape("异常类型记录未全部隔离")
            }
            guard try scalarText("PRAGMA quick_check", in: database) == "ok" else {
                throw RecoveryError.sqlite("完整性检查未通过")
            }

            try execute("COMMIT", in: database)
            transactionStarted = false
            return Report(
                normalizedTransportRows: transportPlan.rowIDs.count,
                quarantinedManualSelectionRows: manualPlan.rowIDs.count,
                backupURL: backupURL
            )
        } catch {
            if transactionStarted { try? execute("ROLLBACK", in: database) }
            throw error
        }
    }

    private struct TransportPlan {
        let canonicalEntityID: Int64
        let staleEntityIDs: [Int64]
        let rowIDs: [Int64]
    }

    private struct ManualPlan {
        let canonicalEntityID: Int64
        let rowIDs: [Int64]
    }

    private static func inspectTransportRepair(in database: OpaquePointer) throws -> TransportPlan {
        let candidates = try integerRows(
            "SELECT p.Z_ENT FROM Z_PRIMARYKEY p " +
            "WHERE p.Z_NAME = 'TransportRecord' AND EXISTS (" +
            "SELECT 1 FROM ANSCKRECORDMETADATA m WHERE m.ZENTITYID = p.Z_ENT) " +
            "ORDER BY p.Z_ENT",
            in: database
        ).map { $0[0] }
        guard candidates.count == 1, let canonical = candidates.first else {
            let duplicateCount = try scalarInt(
                "SELECT COUNT(*) FROM Z_PRIMARYKEY WHERE Z_NAME = 'TransportRecord'",
                in: database
            )
            if duplicateCount <= 1 {
                return TransportPlan(canonicalEntityID: 0, staleEntityIDs: [], rowIDs: [])
            }
            throw RecoveryError.unsafeShape("无法唯一确定交通记录类型")
        }

        let staleRows = try integerRows(
            "SELECT r.Z_PK, r.Z_ENT FROM ZTRANSPORTRECORD r WHERE r.Z_ENT <> ? ORDER BY r.Z_PK",
            integers: [canonical],
            in: database
        )
        guard !staleRows.isEmpty else {
            return TransportPlan(canonicalEntityID: canonical, staleEntityIDs: [], rowIDs: [])
        }

        for row in staleRows {
            let rowID = row[0], staleEntity = row[1]
            let aliasCount = try scalarInt(
                "SELECT COUNT(*) FROM Z_PRIMARYKEY WHERE Z_ENT = ? AND Z_NAME = 'TransportRecord'",
                integers: [staleEntity],
                in: database
            )
            let canonicalMappingCount = try scalarInt(
                "SELECT COUNT(*) FROM ANSCKRECORDMETADATA " +
                "WHERE ZENTITYID = ? AND ZENTITYPK = ?",
                integers: [canonical, rowID],
                in: database
            )
            let staleMappingCount = try scalarInt(
                "SELECT COUNT(*) FROM ANSCKRECORDMETADATA " +
                "WHERE ZENTITYID = ? AND ZENTITYPK = ?",
                integers: [staleEntity, rowID],
                in: database
            )
            guard aliasCount == 1, canonicalMappingCount == 1, staleMappingCount == 0 else {
                throw RecoveryError.unsafeShape("交通记录 \(rowID) 不符合可恢复条件")
            }
        }
        return TransportPlan(
            canonicalEntityID: canonical,
            staleEntityIDs: Array(Set(staleRows.map { $0[1] })).sorted(),
            rowIDs: staleRows.map { $0[0] }
        )
    }

    private static func inspectManualSelectionRepair(in database: OpaquePointer) throws -> ManualPlan {
        let canonicalRows = try integerRows(
            "SELECT Z_ENT FROM Z_PRIMARYKEY WHERE Z_NAME = 'TransportManualSelection' ORDER BY Z_ENT",
            in: database
        )
        guard canonicalRows.count == 1, let canonical = canonicalRows.first?.first else {
            throw RecoveryError.unsafeShape("无法唯一确定手动交通类型")
        }
        let staleRows = try integerRows(
            "SELECT bad.Z_PK FROM ZTRANSPORTMANUALSELECTION bad " +
            "WHERE bad.Z_ENT <> ? ORDER BY bad.Z_PK",
            integers: [canonical],
            in: database
        ).map { $0[0] }
        for rowID in staleRows {
            let exactDuplicateCount = try scalarInt(
                "SELECT COUNT(*) FROM ZTRANSPORTMANUALSELECTION bad " +
                "JOIN ZTRANSPORTMANUALSELECTION good ON good.Z_ENT = ? " +
                "AND good.ZRECORDID IS bad.ZRECORDID " +
                "AND good.ZSTARTTIME IS bad.ZSTARTTIME AND good.ZENDTIME IS bad.ZENDTIME " +
                "AND good.ZVEHICLETYPE IS bad.ZVEHICLETYPE AND good.ZISDELETED IS bad.ZISDELETED " +
                "AND good.ZSTARTLOCATIONOVERRIDE IS bad.ZSTARTLOCATIONOVERRIDE " +
                "AND good.ZENDLOCATIONOVERRIDE IS bad.ZENDLOCATIONOVERRIDE " +
                "WHERE bad.Z_PK = ? AND bad.Z_ENT <> ?",
                integers: [canonical, rowID, canonical],
                in: database
            )
            let cloudMappingCount = try scalarInt(
                "SELECT COUNT(*) FROM ZTRANSPORTMANUALSELECTION bad " +
                "JOIN ANSCKRECORDMETADATA m ON m.ZENTITYID = bad.Z_ENT AND m.ZENTITYPK = bad.Z_PK " +
                "WHERE bad.Z_PK = ?",
                integers: [rowID],
                in: database
            )
            guard exactDuplicateCount > 0, cloudMappingCount == 0 else {
                throw RecoveryError.unsafeShape("手动交通记录 \(rowID) 不符合可隔离条件")
            }
        }
        return ManualPlan(canonicalEntityID: canonical, rowIDs: staleRows)
    }

    private static func hasRequiredTables(in database: OpaquePointer) throws -> Bool {
        let names = [
            "Z_PRIMARYKEY", "ZTRANSPORTRECORD", "ZTRANSPORTMANUALSELECTION",
            "ACHANGE", "ANSCKRECORDMETADATA"
        ]
        for name in names {
            let count = try scalarInt(
                "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = ?",
                texts: [name],
                in: database
            )
            if count != 1 { return false }
        }
        return true
    }

    private static func createBackup(
        sourceStoreURL: URL,
        supportDirectory: URL
    ) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let directory = supportDirectory
            .appendingPathComponent("CloudSyncRecovery", isDirectory: true)
            .appendingPathComponent(
                formatter.string(from: Date()) + "-" + UUID().uuidString,
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let backupURL = directory.appendingPathComponent(sourceStoreURL.lastPathComponent)

        // The caller holds BEGIN IMMEDIATE on a separate connection, so no
        // writer can change the store while this read-only snapshot is made.
        // sqlite3_backup cannot use that write-transaction connection as its
        // own source on all supported OS versions.
        var source: OpaquePointer?
        guard sqlite3_open_v2(
            sourceStoreURL.path,
            &source,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK, let source else {
            if let source { sqlite3_close(source) }
            throw RecoveryError.sqlite("无法读取恢复备份来源")
        }
        defer { sqlite3_close(source) }
        sqlite3_busy_timeout(source, 15_000)

        var destination: OpaquePointer?
        guard sqlite3_open_v2(
            backupURL.path,
            &destination,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK, let destination else {
            if let destination { sqlite3_close(destination) }
            throw RecoveryError.sqlite("无法创建恢复备份")
        }
        defer { sqlite3_close(destination) }
        guard let backup = sqlite3_backup_init(destination, "main", source, "main") else {
            throw RecoveryError.sqlite(String(cString: sqlite3_errmsg(destination)))
        }
        let stepResult = sqlite3_backup_step(backup, -1)
        let finishResult = sqlite3_backup_finish(backup)
        guard stepResult == SQLITE_DONE, finishResult == SQLITE_OK else {
            throw RecoveryError.sqlite("数据库备份未完成")
        }

        for name in [".dfk_v5_stable_SUPPORT", "dfk_v5_stable_ckAssets"] {
            let sourceURL = supportDirectory.appendingPathComponent(name, isDirectory: true)
            let destinationURL = directory.appendingPathComponent(name, isDirectory: true)
            if FileManager.default.fileExists(atPath: sourceURL.path) {
                try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
            }
        }
        return backupURL
    }

    private static func execute(
        _ sql: String,
        integers: [Int64] = [],
        texts: [String] = [],
        in database: OpaquePointer
    ) throws {
        let statement = try prepare(sql, integers: integers, texts: texts, in: database)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw RecoveryError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
    }

    private static func scalarInt(
        _ sql: String,
        integers: [Int64] = [],
        texts: [String] = [],
        in database: OpaquePointer
    ) throws -> Int64 {
        let rows = try integerRows(sql, integers: integers, texts: texts, in: database)
        return rows.first?.first ?? 0
    }

    private static func scalarText(_ sql: String, in database: OpaquePointer) throws -> String {
        let statement = try prepare(sql, in: database)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let value = sqlite3_column_text(statement, 0) else {
            throw RecoveryError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
        return String(cString: value)
    }

    private static func integerRows(
        _ sql: String,
        integers: [Int64] = [],
        texts: [String] = [],
        in database: OpaquePointer
    ) throws -> [[Int64]] {
        let statement = try prepare(sql, integers: integers, texts: texts, in: database)
        defer { sqlite3_finalize(statement) }
        var rows: [[Int64]] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                rows.append((0..<sqlite3_column_count(statement)).map {
                    sqlite3_column_int64(statement, $0)
                })
            case SQLITE_DONE:
                return rows
            default:
                throw RecoveryError.sqlite(String(cString: sqlite3_errmsg(database)))
            }
        }
    }

    private static func prepare(
        _ sql: String,
        integers: [Int64] = [],
        texts: [String] = [],
        in database: OpaquePointer
    ) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw RecoveryError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
        var parameter = 1
        for value in integers {
            guard sqlite3_bind_int64(statement, Int32(parameter), value) == SQLITE_OK else {
                sqlite3_finalize(statement)
                throw RecoveryError.sqlite(String(cString: sqlite3_errmsg(database)))
            }
            parameter += 1
        }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for value in texts {
            guard sqlite3_bind_text(statement, Int32(parameter), value, -1, transient) == SQLITE_OK else {
                sqlite3_finalize(statement)
                throw RecoveryError.sqlite(String(cString: sqlite3_errmsg(database)))
            }
            parameter += 1
        }
        return statement
    }
}
