package import SwiftHttpServerExample
package import Wire

// Supersede the app's production `ServerConfig` (fixed port 8080) with an OS-ephemeral port (0), so the
// harness's server binds a free loopback port the suite trait reads back — no collision with a fixed port.
// Provider-for-provider `@Replaces`.

@Provides @Replaces
package func testServerConfig() -> ServerConfig {
    ServerConfig(host: "127.0.0.1", port: 0)
}
