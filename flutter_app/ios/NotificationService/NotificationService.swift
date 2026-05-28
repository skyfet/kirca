import UserNotifications
import Security
import CryptoKit

/// Notification Service Extension for kirca E2E pushes.
///
/// Offline E2E messages arrive as `aps.mutable-content = 1` pushes carrying
/// only `{room_id, msg_id}` (no plaintext leaves the device). This extension
/// fetches the single message over HTTPS, decrypts it with the room key the
/// Flutter app mirrored into the shared App Group keychain, and rewrites the
/// banner body with the decrypted text.
///
/// CRYPTO CONTRACT (must match flutter_app/lib/crypto/e2e.dart exactly):
///   * Algorithm: AES-256-GCM (32-byte room key).
///   * IV / nonce: 12 random bytes, transported as the `iv` field (base64).
///   * Ciphertext field (`ciphertext`, base64): cipherText || tag, where the
///     16-byte GCM authentication tag is APPENDED to the end of the ciphertext
///     (see E2E.wrapWithKey: `ct = cipherText + mac.bytes`).
///   * No AAD on message encryption (E2E.encryptMessage passes none).
///   * Plaintext is UTF-8.
///
/// SHARED KEYCHAIN CONTRACT (must match flutter_secure_storage 9.x + the
/// IOSOptions used in shared_secrets.dart):
///   * kSecClass        = kSecClassGenericPassword
///   * kSecAttrService  = "flutter_secure_storage_service"  (plugin default)
///   * kSecAttrAccount  = the logical key (e.g. "auth_token")
///   * kSecAttrAccessGroup = "group.com.example.kirca"
///
/// On ANY failure (missing data, network error, decrypt failure, timeout) we
/// deliver the original push untouched — we never drop a notification.
class NotificationService: UNNotificationServiceExtension {

    // Must match SharedSecrets.appGroup in shared_secrets.dart and the
    // entitlements in both Runner and this extension.
    private static let appGroup = "group.com.example.kirca"
    // flutter_secure_storage's AppleOptions.defaultAccountName.
    private static let keychainService = "flutter_secure_storage_service"

    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttemptContent: UNMutableNotificationContent?
    private var fetchTask: URLSessionDataTask?

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        self.contentHandler = contentHandler
        let mutable = request.content.mutableCopy() as? UNMutableNotificationContent
        self.bestAttemptContent = mutable

        guard let bestAttempt = mutable else {
            contentHandler(request.content)
            return
        }

        let info = request.content.userInfo
        guard
            let roomId = stringValue(info["room_id"]),
            let msgId = stringValue(info["msg_id"]),
            let token = readKeychain(account: "auth_token"),
            let baseURL = readKeychain(account: "api_base_url"),
            let url = URL(string: "\(trimTrailingSlash(baseURL))/rooms/\(roomId)/messages/\(msgId)")
        else {
            // Not an E2E push we can enrich (or secrets unavailable) — deliver
            // the generic notification unchanged.
            deliver()
            return
        }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        // Matches api.dart: Authorization: Bearer <token>
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 20

        fetchTask = URLSession.shared.dataTask(with: req) { [weak self] data, response, _ in
            guard let self = self else { return }
            defer { self.deliver() }

            guard
                let http = response as? HTTPURLResponse, http.statusCode == 200,
                let data = data,
                let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { return }

            // The single-message endpoint may nest under "message" or return
            // the message fields at the top level; accept either shape.
            let msg = (json["message"] as? [String: Any]) ?? json

            guard
                let ciphertextB64 = msg["ciphertext"] as? String,
                let ivB64 = msg["iv"] as? String,
                let keyVersion = self.intValue(msg["key_version"]),
                let roomKey = self.readKeychain(
                    account: "roomkey_\(roomId)_\(keyVersion)"
                ),
                let keyData = Data(base64Encoded: roomKey),
                let plaintext = self.decrypt(
                    ciphertextB64: ciphertextB64,
                    ivB64: ivB64,
                    key: keyData
                )
            else { return }

            bestAttempt.body = self.truncate(plaintext, max: 150)
            // Prefer a human-friendly sender name for the title if present.
            if let sender = (msg["sender"] as? String) ?? (msg["username"] as? String),
               !sender.isEmpty {
                bestAttempt.title = sender
            }
        }
        fetchTask?.resume()
    }

    override func serviceExtensionTimeWillExpire() {
        // System is about to kill us — hand back whatever we have.
        fetchTask?.cancel()
        deliver()
    }

    // MARK: - Delivery (idempotent)

    private func deliver() {
        guard let handler = contentHandler, let content = bestAttemptContent else { return }
        // Clear so a later serviceExtensionTimeWillExpire / completion can't
        // call the handler twice.
        contentHandler = nil
        bestAttemptContent = nil
        handler(content)
    }

    // MARK: - AES-256-GCM (tag appended to ciphertext, 12-byte nonce)

    private func decrypt(ciphertextB64: String, ivB64: String, key: Data) -> String? {
        guard
            let ctAndTag = Data(base64Encoded: ciphertextB64),
            let iv = Data(base64Encoded: ivB64),
            iv.count == 12,
            ctAndTag.count >= 16,
            key.count == 32
        else { return nil }

        let tagLen = 16
        let cipherText = ctAndTag.prefix(ctAndTag.count - tagLen)
        let tag = ctAndTag.suffix(tagLen)

        do {
            let nonce = try AES.GCM.Nonce(data: iv)
            let box = try AES.GCM.SealedBox(
                nonce: nonce,
                ciphertext: cipherText,
                tag: tag
            )
            let plaintext = try AES.GCM.open(box, using: SymmetricKey(data: key))
            return String(data: plaintext, encoding: .utf8)
        } catch {
            return nil
        }
    }

    // MARK: - Shared App Group keychain read

    /// Reads a UTF-8 string item written by flutter_secure_storage into the
    /// shared App Group access-group. Returns nil if absent or unreadable.
    private func readKeychain(account: String) -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: NotificationService.keychainService,
            kSecAttrAccount: account,
            kSecAttrAccessGroup: NotificationService.appGroup,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var ref: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &ref)
        guard status == errSecSuccess, let data = ref as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Small helpers

    private func stringValue(_ any: Any?) -> String? {
        if let s = any as? String { return s }
        if let n = any as? NSNumber { return n.stringValue }
        return nil
    }

    private func intValue(_ any: Any?) -> Int? {
        if let n = any as? NSNumber { return n.intValue }
        if let i = any as? Int { return i }
        if let s = any as? String { return Int(s) }
        return nil
    }

    private func trimTrailingSlash(_ s: String) -> String {
        s.hasSuffix("/") ? String(s.dropLast()) : s
    }

    private func truncate(_ s: String, max: Int) -> String {
        guard s.count > max else { return s }
        return String(s.prefix(max)) + "\u{2026}"
    }
}
