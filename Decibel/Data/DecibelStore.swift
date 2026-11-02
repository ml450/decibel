import Foundation

/// Per-minute listening log and device profiles in ~/Library/Application Support/Decibel/decibel.sqlite.
final class DecibelStore {
    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Decibel", isDirectory: true)
    }

    /// Moves data recorded under the app's previous name ("Hearing") to the new location, once.
    static func migrateLegacyDirectory() {
        let fm = FileManager.default
        let legacy = defaultDirectory.deletingLastPathComponent().appendingPathComponent("Hearing", isDirectory: true)
        guard fm.fileExists(atPath: legacy.path), !fm.fileExists(atPath: defaultDirectory.path) else { return }
        do {
            try fm.moveItem(at: legacy, to: defaultDirectory)
            for suffix in ["", "-wal", "-shm"] {
                let old = defaultDirectory.appendingPathComponent("hearing.sqlite" + suffix)
                if fm.fileExists(atPath: old.path) {
                    try fm.moveItem(at: old, to: defaultDirectory.appendingPathComponent("decibel.sqlite" + suffix))
                }
            }
        } catch {
            log.error("Migrating data failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    let url: URL
    private let db: SQLiteDB

    init(directory: URL = DecibelStore.defaultDirectory) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent("decibel.sqlite")
        db = try SQLiteDB(path: url.path)
        try db.execute("""
            PRAGMA journal_mode = WAL;
            CREATE TABLE IF NOT EXISTS devices (
                uid        TEXT PRIMARY KEY,
                name       TEXT NOT NULL,
                transport  TEXT NOT NULL,
                kind       TEXT NOT NULL,
                offset_db  REAL NOT NULL,
                calibrated INTEGER NOT NULL DEFAULT 0
            );
            CREATE TABLE IF NOT EXISTS minutes (
                ts         INTEGER NOT NULL,  -- minute start, unix seconds
                device_uid TEXT NOT NULL,
                avg_db     REAL NOT NULL,     -- Leq dB(A) for the minute
                seconds    INTEGER NOT NULL,  -- seconds with sound above the silence floor
                energy     REAL NOT NULL,     -- seconds * 10^(avg_db/10), for fast aggregation
                PRIMARY KEY (ts, device_uid)
            );
            CREATE INDEX IF NOT EXISTS minutes_device_ts ON minutes(device_uid, ts);
            """)
    }

    // MARK: Devices

    func devices() throws -> [DeviceProfile] {
        var out: [DeviceProfile] = []
        try db.query("SELECT uid, name, transport, kind, offset_db, calibrated FROM devices") { r in
            out.append(DeviceProfile(uid: r.string(0), name: r.string(1),
                                     transport: Transport(rawValue: r.string(2)) ?? .other,
                                     kind: DeviceKind(rawValue: r.string(3)) ?? .externalSpeakers,
                                     offset: r.double(4), calibrated: r.int(5) != 0))
        }
        return out
    }

    func save(_ p: DeviceProfile) throws {
        try db.run("""
            INSERT INTO devices (uid, name, transport, kind, offset_db, calibrated) VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(uid) DO UPDATE SET name = excluded.name, transport = excluded.transport,
                kind = excluded.kind, offset_db = excluded.offset_db, calibrated = excluded.calibrated
            """, [.text(p.uid), .text(p.name), .text(p.transport.rawValue), .text(p.kind.rawValue),
                  .double(p.offset), .int(p.calibrated ? 1 : 0)])
    }

    // MARK: Minutes

    struct MinuteKey: Hashable {
        let minute: Int64
        let uid: String
    }

    /// Adds seconds/energy to existing minute rows (safe to call with partial minutes).
    func add(_ entries: [MinuteKey: LevelAccumulator]) throws {
        guard !entries.isEmpty else { return }
        try db.transaction {
            for (key, acc) in entries where acc.seconds > 0 {
                var total = acc
                try db.query("SELECT seconds, energy FROM minutes WHERE ts = ? AND device_uid = ?",
                             [.int(key.minute), .text(key.uid)]) { r in
                    total.add(seconds: Double(r.int(0)), energy: r.double(1))
                }
                try db.run("INSERT OR REPLACE INTO minutes (ts, device_uid, avg_db, seconds, energy) VALUES (?, ?, ?, ?, ?)",
                           [.int(key.minute), .text(key.uid), .double(total.leq ?? 0),
                            .int(Int64(total.seconds.rounded())), .double(total.energy)])
            }
        }
    }

    func summary(for range: TimeRange, now: Date = Date(), calendar: Calendar = .current) throws -> RangeSummary {
        let interval = range.interval(now: now, calendar: calendar)
        var buckets: [Date: LevelAccumulator] = [:]
        var devices: [String: LevelAccumulator] = [:]
        var total = LevelAccumulator()

        // Pre-aggregate to 15-minute slots (every time zone offset is a multiple of 15 min).
        try db.query("""
            SELECT (ts / 900) * 900 AS slot, device_uid, SUM(seconds), SUM(energy)
            FROM minutes WHERE ts >= ? AND ts < ? GROUP BY slot, device_uid
            """, [.int(Int64(interval.start.timeIntervalSince1970)), .int(Int64(interval.end.timeIntervalSince1970))]) { r in
            let date = Date(timeIntervalSince1970: TimeInterval(r.int(0)))
            let start = calendar.dateInterval(of: range.bucket, for: date)?.start ?? date
            let s = Double(r.int(2)), e = r.double(3)
            buckets[start, default: .init()].add(seconds: s, energy: e)
            devices[r.string(1), default: .init()].add(seconds: s, energy: e)
            total.add(seconds: s, energy: e)
        }

        return RangeSummary(
            interval: interval,
            seconds: total.seconds,
            avgDB: total.leq,
            buckets: buckets.compactMap { date, acc in acc.leq.map { Bucket(start: date, seconds: acc.seconds, avgDB: $0) } }
                .sorted { $0.start < $1.start },
            devices: devices.compactMapValues { acc in acc.leq.map { DeviceUsage(seconds: acc.seconds, avgDB: $0) } })
    }

    /// Rolling 7-day dose (1.0 = 80 dB(A) for 40 h, 3 dB exchange rate).
    func weeklyDose(now: Date = Date()) throws -> Double {
        var dose = 0.0
        try db.query("SELECT seconds, avg_db FROM minutes WHERE ts >= ?",
                     [.int(Int64(now.timeIntervalSince1970 - 7 * 86_400))]) { r in
            dose += Dose.fraction(seconds: Double(r.int(0)), db: r.double(1))
        }
        return dose
    }
}
