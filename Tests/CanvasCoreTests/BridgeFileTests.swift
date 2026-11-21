import XCTest
@testable import CanvasCore

final class BridgeFileTests: XCTestCase {
    func testReplacesAnExistingFileWithAPrivateOneAndLeavesNoTemporaryFiles() throws {
        let url = try temporaryBridgeFileURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("old".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)

        try BridgeFile(port: 1234, token: "abc", pid: 42).write(to: url)

        XCTAssertEqual(try readBridgeFile(url).token, "abc")
        XCTAssertEqual(try readBridgeFile(url).port, 1234)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int, 0o600)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path), ["bridge.json"])
    }

    func testReplacesASymlinkInsteadOfWritingThroughIt() throws {
        let url = try temporaryBridgeFileURL()
        let folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent("target.txt")
        try Data("keep".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)

        try BridgeFile(port: 1, token: "t", pid: 1).write(to: url)

        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "keep")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType, .typeRegular)
    }
}
