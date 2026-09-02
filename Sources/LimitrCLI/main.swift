import Foundation
import LimitrCore

@main
struct LimitrCLI {
    static func main() async {
        let includeClaude = CommandLine.arguments.contains("--claude")
        do {
            let home = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex")
            let liveProvider = CodexLiveProvider(codexHome: home)
            var windows: [UsageWindow]
            if let liveWindows = try? await liveProvider.fetch() {
                windows = liveWindows
            } else {
                windows = try CodexProvider().fetch()
            }
            var extraUsage: ExtraUsage?
            if includeClaude {
                let claude = try await ClaudeProvider().fetch()
                windows += claude.windows
                extraUsage = claude.extraUsage
            }
            let snapshot = UsageSnapshot(windows: windows, extraUsage: extraUsage)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
            print(String(decoding: try encoder.encode(snapshot), as: UTF8.self))
        } catch {
            FileHandle.standardError.write(Data("limitr: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}
