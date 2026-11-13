import Foundation

/// Checksum bookkeeping: hashes from Deep Verify, checksum mismatches, and the
/// resume point of an interrupted Deep Verify run.
extension StateStore {
    static let checksumErrorPrefix = verifyPrefix + "checksum mismatch"

    /// The local file was hashed and matches every known reference (or had none: baseline).
    func recordHash(_ path: String, sha256: String, at date: Date) throws {
        try db.query("""
            UPDATE file SET sha256 = ?, hashed_at = ?, verified_at = ?, last_error = NULL WHERE path = ?
            """, [.text(sha256), SQLValue(date), SQLValue(date), .text(path)])
    }

    /// The local bytes do not match their reference. The stored reference is kept and the
    /// file is never overwritten: it becomes a conflict until the user repairs it.
    func markChecksumMismatch(_ path: String, algorithm: HashAlgorithm) throws {
        let message = "checksum mismatch (\(algorithm.rawValue))"
        try db.query("""
            UPDATE file SET status = 'conflict', note = ?, replace_ok = 0, verified_at = NULL,
                last_error = ? WHERE path = ?
            """, [.text(message), .text(Self.verifyPrefix + message), .text(path)])
    }

    // MARK: - Deep Verify resume point

    private static let deepVerifyKey = "deep_verify_started_at"

    func deepVerifyStartedAt() throws -> Date? {
        try db.query("SELECT value FROM meta WHERE key = ?", [.text(Self.deepVerifyKey)]).first?.date("value")
    }

    func setDeepVerifyStartedAt(_ date: Date?) throws {
        guard let date else {
            try db.query("DELETE FROM meta WHERE key = ?", [.text(Self.deepVerifyKey)])
            return
        }
        try db.query("INSERT OR REPLACE INTO meta(key, value) VALUES (?, ?)", [.text(Self.deepVerifyKey), SQLValue(date)])
    }
}
