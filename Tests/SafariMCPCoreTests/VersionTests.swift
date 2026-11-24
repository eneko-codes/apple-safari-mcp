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

    /// The server is built from the system's own frameworks and nothing else. A dependency
    /// is a decision for the owner, so adding one has to break this test first.
    @Test("The package declares no third-party dependency")
    func noDependencies() throws {
        let package = try String(contentsOf: Self.root.appendingPathComponent("Package.swift"), encoding: .utf8)
        #expect(!package.contains(".package("), "Package.swift declares a dependency")
        #expect(!package.contains(".product("))
    }
}
