import Foundation
import LocalAuthentication
import Security
import SwiftUI

@MainActor
final class SettingsStore: ObservableObject {
    @Published var bridgeURL: String {
        didSet { defaults.set(bridgeURL, forKey: Keys.bridgeURL) }
    }
    @Published var refreshMinutes: Int {
        didSet { defaults.set(refreshMinutes, forKey: Keys.refreshMinutes) }
    }
    @Published var launchAtLogin: Bool = false

    private let defaults = UserDefaults.standard
    private let keychain = KeychainStore(service: "cn.gamepulse.desktop")
    private var cachedBridgeToken: String
    private var cachedMihoyoCookie: String
    private var cachedMihoyoZZZCookie: String
    private var cachedSklandToken: String
    private var cachedKuroToken: String

    init() {
        cachedBridgeToken = keychain.read(account: Keys.bridgeToken) ?? ""
        // Ad-hoc signed development builds get a new Keychain identity after
        // every rebuild. Keep a local fallback so an update never turns into
        // an endless Keychain-password loop. The Keychain remains the primary
        // store for installed/stably signed builds.
        let localCookie = defaults.string(forKey: Keys.mihoyoCookieFallback) ?? ""
        if !localCookie.isEmpty {
            cachedMihoyoCookie = localCookie
        } else {
            cachedMihoyoCookie = keychain.read(account: Keys.mihoyoCookie) ?? ""
            if !cachedMihoyoCookie.isEmpty {
                defaults.set(cachedMihoyoCookie, forKey: Keys.mihoyoCookieFallback)
            }
        }
        let localZZZCookie = defaults.string(forKey: Keys.mihoyoZZZCookieFallback) ?? ""
        if !localZZZCookie.isEmpty {
            cachedMihoyoZZZCookie = localZZZCookie
        } else {
            cachedMihoyoZZZCookie = keychain.read(account: Keys.mihoyoZZZCookie) ?? ""
            if !cachedMihoyoZZZCookie.isEmpty {
                defaults.set(cachedMihoyoZZZCookie, forKey: Keys.mihoyoZZZCookieFallback)
            }
        }
        cachedSklandToken = defaults.string(forKey: Keys.sklandTokenFallback)
            ?? keychain.read(account: Keys.sklandToken)
            ?? ""
        cachedKuroToken = defaults.string(forKey: Keys.kuroTokenFallback)
            ?? keychain.read(account: Keys.kuroToken)
            ?? ""
        bridgeURL = defaults.string(forKey: Keys.bridgeURL) ?? ""
        let saved = defaults.integer(forKey: Keys.refreshMinutes)
        refreshMinutes = saved == 0 ? 10 : saved
    }

    var bridgeToken: String {
        get { cachedBridgeToken }
        set {
            objectWillChange.send()
            cachedBridgeToken = newValue
            keychain.write(newValue, account: Keys.bridgeToken)
        }
    }

    var mihoyoCookie: String {
        get { cachedMihoyoCookie }
        set {
            objectWillChange.send()
            cachedMihoyoCookie = newValue
            if newValue.isEmpty {
                defaults.removeObject(forKey: Keys.mihoyoCookieFallback)
            } else {
                defaults.set(newValue, forKey: Keys.mihoyoCookieFallback)
            }
            keychain.write(newValue, account: Keys.mihoyoCookie)
        }
    }

    var mihoyoZZZCookie: String {
        get { cachedMihoyoZZZCookie }
        set {
            objectWillChange.send()
            cachedMihoyoZZZCookie = newValue
            if newValue.isEmpty {
                defaults.removeObject(forKey: Keys.mihoyoZZZCookieFallback)
            } else {
                defaults.set(newValue, forKey: Keys.mihoyoZZZCookieFallback)
            }
            keychain.write(newValue, account: Keys.mihoyoZZZCookie)
        }
    }

    var sklandToken: String {
        get { cachedSklandToken }
        set {
            objectWillChange.send()
            cachedSklandToken = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            persistSecret(cachedSklandToken, keychainKey: Keys.sklandToken, fallbackKey: Keys.sklandTokenFallback)
        }
    }

    var kuroToken: String {
        get { cachedKuroToken }
        set {
            objectWillChange.send()
            cachedKuroToken = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            persistSecret(cachedKuroToken, keychainKey: Keys.kuroToken, fallbackKey: Keys.kuroTokenFallback)
        }
    }

    var hasMihoyoLogin: Bool { !mihoyoCookie.isEmpty }

    var hasMihoyoZZZLogin: Bool { !mihoyoZZZCookie.isEmpty }

    var hasSklandLogin: Bool { !sklandToken.isEmpty }

    var hasKuroLogin: Bool { !kuroToken.isEmpty }

    var hasAnyLiveAccount: Bool {
        hasMihoyoLogin || hasMihoyoZZZLogin || hasSklandLogin || hasKuroLogin
    }

    var hasMihoyoFullLogin: Bool {
        hasSToken(in: mihoyoCookie)
    }

    var hasMihoyoZZZFullLogin: Bool {
        hasSToken(in: mihoyoZZZCookie)
    }

    private func hasSToken(in cookie: String) -> Bool {
        cookie.split(separator: ";").contains { part in
            let key = part.split(separator: "=", maxSplits: 1).first?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return key == "stoken" || key == "stoken_v2"
        }
    }

    private func persistSecret(_ value: String, keychainKey: String, fallbackKey: String) {
        if value.isEmpty {
            defaults.removeObject(forKey: fallbackKey)
        } else {
            defaults.set(value, forKey: fallbackKey)
        }
        keychain.write(value, account: keychainKey)
    }

    var isDemoMode: Bool { bridgeURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private enum Keys {
        static let bridgeURL = "bridgeURL"
        static let bridgeToken = "bridgeToken"
        static let mihoyoCookie = "mihoyoCookie"
        static let mihoyoCookieFallback = "mihoyoCookie.localFallback"
        static let mihoyoZZZCookie = "mihoyoZZZCookie"
        static let mihoyoZZZCookieFallback = "mihoyoZZZCookie.localFallback"
        static let sklandToken = "sklandToken"
        static let sklandTokenFallback = "sklandToken.localFallback"
        static let kuroToken = "kuroToken"
        static let kuroTokenFallback = "kuroToken.localFallback"
        static let refreshMinutes = "refreshMinutes"
    }
}

struct KeychainStore: Sendable {
    let service: String

    func read(account: String) -> String? {
        let context = LAContext()
        context.interactionNotAllowed = true
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func write(_ value: String, account: String) {
        let key: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let context = LAContext()
        context.interactionNotAllowed = true
        var deleteQuery = key
        deleteQuery[kSecUseAuthenticationContext as String] = context
        let deleteStatus = SecItemDelete(deleteQuery as CFDictionary)
        // A previous ad-hoc signature may own this item. Never summon a
        // blocking system password dialog; the local fallback was already
        // updated by SettingsStore.
        guard deleteStatus != errSecInteractionNotAllowed else { return }
        guard !value.isEmpty else { return }
        var item = key
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(item as CFDictionary, nil)
    }
}
