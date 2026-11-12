import Foundation
import Security
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private let keychainBase: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: "lift.backup",
    kSecAttrAccount as String: "database",
]

final class Store {
    static let shared = Store()

    struct StoreError: LocalizedError {
        let errorDescription: String?
    }

    private let tables = ["progress": 3, "sessions": 8, "done": 2, "log": 2, "settings": 2]
    private let lock = NSLock()
    private var db: OpaquePointer?
    private var backupStatus: OSStatus = 0

    private lazy var library: [String: Any]? = {
        guard let url = Bundle.main.url(forResource: "exercises", withExtension: "json", subdirectory: "Web"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }()

    private lazy var templates: [Any] = {
        guard let url = Bundle.main.url(forResource: "templates", withExtension: "json", subdirectory: "Web"),
              let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = object["templates"] as? [Any] else { return [] }
        return list
    }()

    private init() {
        open()
        if isEmpty() {
            restoreFromKeychain()
        } else if keychainDate() == nil {
            mirror()
        }
    }

    func backupInfo() -> [String: Any] {
        let date = keychainDate().map { ISO8601DateFormatter().string(from: $0) } ?? ""
        return ["at": date, "status": Int(backupStatus)]
    }

    func getAll() throws -> [String: Any] {
        guard var out = library else { throw StoreError(errorDescription: "Web/exercises.json is missing or invalid.") }
        lock.lock()
        defer { lock.unlock() }
        for name in tables.keys {
            out[name] = read(name).filter { row in row.contains { cell in !cell.isEmpty } }
        }
        out["templates"] = templates
        return out
    }

    func save(batch: Any?) throws {
        guard let raw = batch as? [String: Any] else { throw StoreError(errorDescription: "Bad data") }
        var clean: [String: [[String]]] = [:]
        for (name, rows) in raw {
            guard let width = tables[name] else { throw StoreError(errorDescription: "Unknown table: \(name)") }
            clean[name] = (rows as? [Any] ?? []).map { item in
                let row = item as? [Any] ?? []
                return (0..<width).map { i in i < row.count ? text(row[i]) : "" }
            }
        }
        try commit(clean)
        mirror()
    }

    private func open() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("lift.sqlite").path
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { return }
        exec("PRAGMA journal_mode = WAL")
        exec("PRAGMA synchronous = NORMAL")
        exec("CREATE TABLE IF NOT EXISTS rows (tbl TEXT NOT NULL, pos INTEGER NOT NULL, data TEXT NOT NULL, PRIMARY KEY (tbl, pos)) WITHOUT ROWID")
    }

    @discardableResult
    private func exec(_ sql: String) -> Bool {
        sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }

    private func failure(_ what: String) -> StoreError {
        StoreError(errorDescription: "Database error (\(what)): " + (db.map { String(cString: sqlite3_errmsg($0)) } ?? "not open"))
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let ready = statement else { throw failure("prepare") }
        return ready
    }

    private func read(_ table: String) -> [[String]] {
        guard let statement = try? prepare("SELECT data FROM rows WHERE tbl = ? ORDER BY pos") else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, table, -1, sqliteTransient)
        var out: [[String]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let cell = sqlite3_column_text(statement, 0),
                  let row = try? JSONDecoder().decode([String].self, from: Data(String(cString: cell).utf8)) else { continue }
            out.append(row)
        }
        return out
    }

    private func commit(_ batch: [String: [[String]]]) throws {
        lock.lock()
        defer { lock.unlock() }
        guard exec("BEGIN IMMEDIATE") else { throw failure("begin") }
        do {
            let delete = try prepare("DELETE FROM rows WHERE tbl = ?")
            defer { sqlite3_finalize(delete) }
            let insert = try prepare("INSERT INTO rows (tbl, pos, data) VALUES (?, ?, ?)")
            defer { sqlite3_finalize(insert) }
            for (name, rows) in batch {
                sqlite3_reset(delete)
                sqlite3_bind_text(delete, 1, name, -1, sqliteTransient)
                guard sqlite3_step(delete) == SQLITE_DONE else { throw failure("delete") }
                for (index, row) in rows.enumerated() {
                    let json = String(decoding: try JSONEncoder().encode(row), as: UTF8.self)
                    sqlite3_reset(insert)
                    sqlite3_bind_text(insert, 1, name, -1, sqliteTransient)
                    sqlite3_bind_int(insert, 2, Int32(index))
                    sqlite3_bind_text(insert, 3, json, -1, sqliteTransient)
                    guard sqlite3_step(insert) == SQLITE_DONE else { throw failure("insert") }
                }
            }
            guard exec("COMMIT") else { throw failure("commit") }
        } catch {
            exec("ROLLBACK")
            throw error
        }
    }

    private func isEmpty() -> Bool {
        guard let statement = try? prepare("SELECT COUNT(*) FROM rows") else { return false }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW && sqlite3_column_int(statement, 0) == 0
    }

    private func mirror() {
        lock.lock()
        defer { lock.unlock() }
        var snapshot: [String: [[String]]] = [:]
        for name in tables.keys {
            snapshot[name] = read(name)
        }
        guard let json = try? JSONEncoder().encode(snapshot),
              let packed = try? (json as NSData).compressed(using: .lzfse) as Data else { return }
        backupStatus = keychainWrite(packed)
    }

    private func restoreFromKeychain() {
        guard let packed = keychainRead(),
              let json = try? (packed as NSData).decompressed(using: .lzfse) as Data,
              let all = try? JSONDecoder().decode([String: [[String]]].self, from: json) else { return }
        try? commit(all.filter { tables[$0.key] != nil })
    }

    private func keychainWrite(_ data: Data) -> OSStatus {
        var status = SecItemUpdate(keychainBase as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = keychainBase
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(add as CFDictionary, nil)
        }
        return status
    }

    private func keychainRead() -> Data? {
        var query = keychainBase
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    private func keychainDate() -> Date? {
        var query = keychainBase
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let attributes = item as? [String: Any] else { return nil }
        return attributes[kSecAttrModificationDate as String] as? Date
    }

    private func text(_ value: Any) -> String {
        if let number = value as? NSNumber { return number.stringValue }
        return (value as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
