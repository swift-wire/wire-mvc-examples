// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 the swift-wire project authors

import Controllers
import Valkey
import Wire

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// This runtime's session store — the app `@Singleton(as: SessionManager.self)`, backed by the same real
/// Valkey the todos use, sharing the injected `ValkeyClient` (one connection pool across the repository,
/// this store, and the service group). A token maps to `session:<token>`; the id is minted once and read
/// back thereafter, so the same token resolves to the same id across requests. Injects the store's driver
/// just like `ValkeyTodoRepository`, binding via the same opaque-lift pattern.
@Singleton(as: SessionManager.self)
struct ValkeySessionManager: SessionManager {
    private let client: ValkeyClient

    @Inject init(client: ValkeyClient) {
        self.client = client
    }

    func sessionID(for token: String) async throws -> String {
        let key = Self.key(token)
        if let stored = try await client.get(key) {
            return String(decoding: Data(stored), as: UTF8.self)
        }
        let created = UUID().uuidString
        _ = try await client.set(key, value: Data(created.utf8))
        return created
    }

    private static func key(_ token: String) -> ValkeyKey { ValkeyKey("session:\(token)") }
}
