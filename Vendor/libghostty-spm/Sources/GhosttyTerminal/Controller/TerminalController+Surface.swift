//
//  TerminalController+Surface.swift
//  libghostty-spm
//

import Foundation
import GhosttyKit

extension TerminalController {
    /// Creates a new Ghostty surface with the given configuration.
    ///
    /// The `platformSetup` closure lets the caller fill in
    /// platform-specific fields (`platform_tag`, `platform`, `scale_factor`)
    /// on the raw surface config struct before the surface is created.
    func createSurface(
        bridge: TerminalCallbackBridge,
        configuration: TerminalSurfaceOptions,
        platformSetup: (inout ghostty_surface_config_s) -> Void
    ) -> ghostty_surface_t? {
        guard let app else { return nil }

        var surfaceConfig = ghostty_surface_config_new()
        surfaceConfig.userdata = Unmanaged.passUnretained(bridge).toOpaque()
        surfaceConfig.context = configuration.context.ghosttyValue
        configureBackend(&surfaceConfig, from: configuration)

        if let fontSize = configuration.fontSize {
            surfaceConfig.font_size = fontSize
        }

        // Like `working_directory` below, the pointers only need to outlive
        // `ghostty_surface_new`, which copies the values during surface init.
        return withEnvVarEntries(configuration.envVars) { entries, count in
            surfaceConfig.env_vars = entries
            surfaceConfig.env_var_count = count
            return finalizeSurface(
                app: app,
                bridge: bridge,
                configuration: configuration,
                config: &surfaceConfig,
                workingDirectory: configuration.workingDirectory,
                platformSetup: platformSetup
            )
        }
    }

    /// Runs `body` with a C representation of `envVars` (`ghostty_env_var_s`
    /// entries) that stays valid for the duration of the call.
    private func withEnvVarEntries<T>(
        _ envVars: [String: String],
        _ body: (UnsafeMutablePointer<ghostty_env_var_s>?, Int) -> T
    ) -> T {
        guard !envVars.isEmpty else { return body(nil, 0) }
        let strings: [(key: UnsafeMutablePointer<CChar>, value: UnsafeMutablePointer<CChar>)] =
            envVars.map { (strdup($0.key), strdup($0.value)) }
        defer {
            for entry in strings {
                free(entry.key)
                free(entry.value)
            }
        }
        var entries = strings.map { ghostty_env_var_s(key: $0.key, value: $0.value) }
        return entries.withUnsafeMutableBufferPointer { buffer in
            body(buffer.baseAddress, buffer.count)
        }
    }

    func retain(_ bridge: TerminalCallbackBridge) {
        retainedBridges.append(bridge)
    }

    func remove(_ bridge: TerminalCallbackBridge) {
        retainedBridges.removeAll { $0 === bridge }
    }

    var retainedBridgeCount: Int {
        retainedBridges.count
    }

    private func configureBackend(
        _ config: inout ghostty_surface_config_s,
        from options: TerminalSurfaceOptions
    ) {
        guard case let .inMemory(session) = options.backend else {
            config.backend = GHOSTTY_SURFACE_IO_BACKEND_EXEC
            return
        }

        config.backend = GHOSTTY_SURFACE_IO_BACKEND_HOST_MANAGED
        config.receive_userdata = Unmanaged.passUnretained(session).toOpaque()
        config.receive_buffer = InMemoryTerminalSession.receiveBufferCallback
        config.receive_resize = InMemoryTerminalSession.receiveResizeCallback
    }

    private func finalizeSurface(
        app: ghostty_app_t,
        bridge: TerminalCallbackBridge,
        configuration: TerminalSurfaceOptions,
        config: inout ghostty_surface_config_s,
        workingDirectory: String?,
        platformSetup: (inout ghostty_surface_config_s) -> Void
    ) -> ghostty_surface_t? {
        guard let workingDirectory else {
            return buildSurface(
                app: app,
                bridge: bridge,
                configuration: configuration,
                config: &config,
                platformSetup: platformSetup
            )
        }

        return workingDirectory.withCString { ptr in
            config.working_directory = ptr
            return buildSurface(
                app: app,
                bridge: bridge,
                configuration: configuration,
                config: &config,
                platformSetup: platformSetup
            )
        }
    }

    private func buildSurface(
        app: ghostty_app_t,
        bridge: TerminalCallbackBridge,
        configuration: TerminalSurfaceOptions,
        config: inout ghostty_surface_config_s,
        platformSetup: (inout ghostty_surface_config_s) -> Void
    ) -> ghostty_surface_t? {
        platformSetup(&config)
        guard let surface = ghostty_surface_new(app, &config) else {
            return nil
        }

        retain(bridge)

        if case let .inMemory(session) = configuration.backend {
            session.setSurface(surface)
        }

        return surface
    }
}
