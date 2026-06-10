import XCTest
@testable import NetworkMonitor

final class GeoIPTests: XCTestCase {
    private var dbPath: String {
        let dir = NSString(string: "~/Library/Application Support/NetworkMonitor").expandingTildeInPath
        return dir + "/GeoLite-City.mmdb"
    }

    private func loadDB() throws -> GeoIP {
        guard FileManager.default.fileExists(atPath: dbPath) else {
            throw XCTSkip("GeoIP database not present — run scripts/fetch-geoip.sh")
        }
        let db = try XCTUnwrap(GeoIP(path: dbPath), "failed to open mmdb")
        return db
    }

    func testKnownIPv4() throws {
        let db = try loadDB()
        // 8.8.8.8 is Google DNS, US.
        let loc = try XCTUnwrap(db.lookup("8.8.8.8"), "no location for 8.8.8.8")
        XCTAssertEqual(loc.countryCode, "US")
        // Plausible North-American coordinates.
        XCTAssertTrue((20...55).contains(loc.latitude), "lat \(loc.latitude)")
        XCTAssertTrue((-130...(-65)).contains(loc.longitude), "lon \(loc.longitude)")
    }

    func testKnownIPv6() throws {
        let db = try loadDB()
        // Cloudflare 1.1.1.1's v6 sibling.
        let loc = try XCTUnwrap(db.lookup("2606:4700:4700::1111"), "no location for cloudflare v6")
        XCTAssertNotNil(loc.countryCode)
    }

    func testPrivateIPHasNoLocation() throws {
        let db = try loadDB()
        // RFC1918 space generally isn't in the DB.
        XCTAssertNil(db.lookup("192.168.1.1"))
    }

    func testGarbageReturnsNil() throws {
        let db = try loadDB()
        XCTAssertNil(db.lookup("not-an-ip"))
    }
}
