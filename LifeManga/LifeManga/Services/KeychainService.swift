//
//  KeychainService.swift
//  LifeManga
//
//  用 iOS Keychain 安全保存后端凭证（以及兼容旧版 OpenAI Key 字段）。
//

import Foundation
import Security

final class KeychainService {

    static let shared = KeychainService()
    private init() {}

    private let service = "com.lifemanga.app"
    private let openAIAccount = "openai_api_key"
    private let backendAccount = "backend_api_key"

    // MARK: - Generic

    @discardableResult
    func saveSecret(_ secret: String, account: String) -> Bool {
        guard let data = secret.data(using: .utf8) else { return false }
        let queryDelete: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(queryDelete as CFDictionary)

        let attributes: [String: Any] = [
            kSecClass as String:        kSecClassGenericPassword,
            kSecAttrService as String:  service,
            kSecAttrAccount as String:  account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecValueData as String:    data
        ]

        let status = SecItemAdd(attributes as CFDictionary, nil)
        return status == errSecSuccess
    }

    func loadSecret(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String:        kSecClassGenericPassword,
            kSecAttrService as String:  service,
            kSecAttrAccount as String:  account,
            kSecReturnData as String:   true,
            kSecMatchLimit as String:   kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8) else {
            return nil
        }
        return key
    }

    @discardableResult
    func deleteSecret(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    // MARK: - OpenAI (legacy compatibility)

    @discardableResult
    func saveAPIKey(_ key: String) -> Bool {
        saveSecret(key, account: openAIAccount)
    }

    func loadAPIKey() -> String? {
        loadSecret(account: openAIAccount)
    }

    @discardableResult
    func deleteAPIKey() -> Bool {
        deleteSecret(account: openAIAccount)
    }

    // MARK: - Backend

    @discardableResult
    func saveBackendAPIKey(_ key: String) -> Bool {
        saveSecret(key, account: backendAccount)
    }

    func loadBackendAPIKey() -> String? {
        loadSecret(account: backendAccount)
    }

    @discardableResult
    func deleteBackendAPIKey() -> Bool {
        deleteSecret(account: backendAccount)
    }
}
