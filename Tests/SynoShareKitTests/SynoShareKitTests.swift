import XCTest
@testable import SynoShareKit

final class ShareLinkTests: XCTestCase {
    func testParsesGofileLink() throws {
        let link = try ShareLink(parsing: "https://gofile.me/AbC12/Xyz789")
        XCTAssertEqual(link.serverID, "AbC12")
        XCTAssertEqual(link.linkID, "Xyz789")
    }

    func testParsesLinkWithoutScheme() throws {
        XCTAssertEqual(try ShareLink(parsing: " gofile.me/AbCdE/Xyz123 ").linkID, "Xyz123")
    }

    func testParsesServerSubdomainLink() throws {
        let link = try ShareLink(parsing: "https://myserver.quickconnect.to/sharing/Xyz123")
        XCTAssertEqual(link.serverID, "myserver")
        XCTAssertEqual(link.linkID, "Xyz123")
    }

    func testRejectsForeignHost() {
        XCTAssertThrowsError(try ShareLink(parsing: "https://example.com/AbCdE/Xyz123"))
    }

    func testRejectsNonAlphanumericIDs() {
        XCTAssertThrowsError(try ShareLink(parsing: "https://gofile.me/Ab..E/Xyz123"))
        XCTAssertThrowsError(try ShareLink(parsing: "https://gofile.me/AbCdE/Xy%2Fz"))
    }
}

final class QuickConnectTests: XCTestCase {
    func testRelayHostMatchesObservedBrowserHost() {
        XCTAssertEqual(QuickConnect.relayHost(serverID: "AbC12", region: "sg3"),
                       "gofile-4162433132.sg3.quickconnect.to")
    }

    func testRelayHostChinaDomain() {
        XCTAssertEqual(QuickConnect.relayHost(serverID: "A", region: "cn1", topDomain: "cn"),
                       "gofile-41.cn1.quickconnect.cn")
    }
}

final class EncodingTests: XCTestCase {
    func testFormEncodingEscapesReservedCharacters() {
        XCTAssertEqual(FormEncoding.encode(["b": "a b&c", "a": "\"/x\""]),
                       "a=%22%2Fx%22&b=a%20b%26c")
    }

    func testJSONLiteralQuotesAndEscapes() {
        XCTAssertEqual(jsonLiteral("name"), "\"name\"")
        XCTAssertEqual(jsonLiteral("a\"b"), "\"a\\\"b\"")
    }

    func testListEntryParsing() {
        let raw: [String: Any] = [
            "name": "f.txt", "path": "/root/f.txt", "isdir": false,
            "additional": ["size": 1234, "time": ["mtime": 1_700_000_000]],
        ]
        let entry = ShareClient.entry(from: raw)
        XCTAssertEqual(entry?.size, 1234)
        XCTAssertEqual(entry?.isDirectory, false)
        XCTAssertEqual(entry?.modified, Date(timeIntervalSince1970: 1_700_000_000))
    }
}
