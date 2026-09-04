import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class SQLiteDatabase {
    private var handle: OpaquePointer?

    var pointer: OpaquePointer {
        guard let handle else {
            preconditionFailure("SQLite database is closed")
        }
        return handle
    }

    init(fileURL: URL) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var opened: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        let status = sqlite3_open_v2(fileURL.path, &opened, flags, nil)
        guard status == SQLITE_OK, let opened else {
            sqlite3_close(opened)
            throw SpeakerProfileStoreError.sqlite("Unable to open \(fileURL.lastPathComponent)")
        }
        handle = opened
        try execute("PRAGMA foreign_keys = ON;")
        try execute("PRAGMA journal_mode = WAL;")
        try execute("PRAGMA busy_timeout = 5000;")
    }

    deinit {
        sqlite3_close(handle)
        handle = nil
    }

    func execute(_ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(pointer, sql, nil, nil, &errorMessage)
        if let errorMessage {
            let text = String(cString: errorMessage)
            sqlite3_free(errorMessage)
            if status != SQLITE_OK {
                throw SpeakerProfileStoreError.sqlite(text)
            }
        }
        guard status == SQLITE_OK else {
            throw sqliteError()
        }
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE;")
        do {
            let value = try body()
            try execute("COMMIT;")
            return value
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    func prepare(_ sql: String) throws -> SQLiteStatement {
        try SQLiteStatement(database: self, sql: sql)
    }

    func sqliteError() -> SpeakerProfileStoreError {
        if let message = sqlite3_errmsg(pointer) {
            return .sqlite(String(cString: message))
        }
        return .sqlite("Unknown SQLite error")
    }
}

final class SQLiteStatement {
    private let database: SQLiteDatabase
    private let statement: OpaquePointer

    init(database: SQLiteDatabase, sql: String) throws {
        var statement: OpaquePointer?
        let status = sqlite3_prepare_v2(database.pointer, sql, -1, &statement, nil)
        guard status == SQLITE_OK, let statement else {
            throw database.sqliteError()
        }
        self.database = database
        self.statement = statement
    }

    deinit {
        sqlite3_finalize(statement)
    }

    func bind(index: Int32, text: String) throws {
        let status = sqlite3_bind_text(statement, index, text, -1, sqliteTransient)
        guard status == SQLITE_OK else { throw database.sqliteError() }
    }

    func bind(index: Int32, optionalText: String?) throws {
        if let optionalText {
            try bind(index: index, text: optionalText)
        } else {
            try bindNull(index: index)
        }
    }

    func bind(index: Int32, int64: Int64) throws {
        let status = sqlite3_bind_int64(statement, index, int64)
        guard status == SQLITE_OK else { throw database.sqliteError() }
    }

    func bind(index: Int32, bool: Bool) throws {
        try bind(index: index, int64: bool ? 1 : 0)
    }

    func bind(index: Int32, double: Double) throws {
        let status = sqlite3_bind_double(statement, index, double)
        guard status == SQLITE_OK else { throw database.sqliteError() }
    }

    func bind(index: Int32, data: Data) throws {
        let status = data.withUnsafeBytes { buffer in
            sqlite3_bind_blob(statement, index, buffer.baseAddress, Int32(buffer.count), sqliteTransient)
        }
        guard status == SQLITE_OK else { throw database.sqliteError() }
    }

    func bindNull(index: Int32) throws {
        let status = sqlite3_bind_null(statement, index)
        guard status == SQLITE_OK else { throw database.sqliteError() }
    }

    /// Returns true when a row is available.
    @discardableResult
    func step() throws -> Bool {
        let status = sqlite3_step(statement)
        switch status {
        case SQLITE_ROW:
            return true
        case SQLITE_DONE:
            return false
        default:
            throw database.sqliteError()
        }
    }

    func int64(at column: Int32) -> Int64 {
        sqlite3_column_int64(statement, column)
    }

    func bool(at column: Int32) -> Bool {
        int64(at: column) != 0
    }

    func double(at column: Int32) -> Double {
        sqlite3_column_double(statement, column)
    }

    func string(at column: Int32) -> String {
        guard let pointer = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: pointer)
    }

    func optionalString(at column: Int32) -> String? {
        if sqlite3_column_type(statement, column) == SQLITE_NULL {
            return nil
        }
        return string(at: column)
    }

    func data(at column: Int32) -> Data {
        guard let pointer = sqlite3_column_blob(statement, column) else { return Data() }
        let count = Int(sqlite3_column_bytes(statement, column))
        return Data(bytes: pointer, count: count)
    }
}
