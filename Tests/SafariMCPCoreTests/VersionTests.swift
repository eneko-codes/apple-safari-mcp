import Foundation
import Testing

@testable import SafariMCPCore

@Suite("Version")
struct VersionTests {

    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// The installer keys on the manifest version alone, so a build whose three version
    /// strings disagree is a build nobody can describe.
    @Test("The server, the manifest and Info.plist carry the same version")
    func versionsAgree() throws {
        let manifestData = try Data(contentsOf: Self.root.appending(path: "extension/manifest.json"))
        let manifest = try #require(
            try JSONSerialization.jsonObject(with: manifestData) as? [String: Any])

        let plistData = try Data(contentsOf: Self.root.appending(path: "Resources/Info.plist"))
        let plist = try #require(
            try PropertyListSerialization.propertyList(from: plistData, format: nil)
                as? [String: Any])

        #expect(manifest["version"] as? String == SafariMCPServer.version)
        #expect(plist["CFBundleShortVersionString"] as? String == SafariMCPServer.version)
    }
}
