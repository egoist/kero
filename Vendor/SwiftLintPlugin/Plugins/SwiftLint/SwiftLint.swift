import PackagePlugin

@main
struct SwiftLint: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) async throws -> [Command] {
        []
    }
}
