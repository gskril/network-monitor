import XCTest
@testable import NetworkMonitor

final class DNSParserTests: XCTestCase {
    // Builds an Ethernet + IPv4 + UDP + DNS-response frame for one question
    // name resolving to the given A/AAAA answers, using a compression pointer
    // for the answer names (as real resolvers do).
    private func makeFrame(question: String, answers: [(type: UInt16, rdata: [UInt8])], rcode: UInt8 = 0, qr: Bool = true) -> [UInt8] {
        func encodeName(_ name: String) -> [UInt8] {
            var bytes: [UInt8] = []
            for label in name.split(separator: ".") {
                bytes.append(UInt8(label.utf8.count))
                bytes.append(contentsOf: Array(label.utf8))
            }
            bytes.append(0)
            return bytes
        }

        var dns: [UInt8] = []
        dns += [0x12, 0x34]                                  // id
        let flags: UInt16 = (qr ? 0x8180 : 0x0100) | UInt16(rcode)
        dns += [UInt8(flags >> 8), UInt8(flags & 0xFF)]      // flags
        dns += [0x00, 0x01]                                  // qdcount
        dns += [UInt8(answers.count >> 8), UInt8(answers.count & 0xFF)] // ancount
        dns += [0x00, 0x00, 0x00, 0x00]                      // ns/ar
        dns += encodeName(question)                          // question name @ offset 12
        dns += [0x00, 0x01, 0x00, 0x01]                      // qtype A, qclass IN
        for answer in answers {
            dns += [0xC0, 0x0C]                              // name → pointer to offset 12
            dns += [UInt8(answer.type >> 8), UInt8(answer.type & 0xFF)]
            dns += [0x00, 0x01]                              // class IN
            dns += [0x00, 0x00, 0x01, 0x2C]                  // ttl 300
            dns += [UInt8(answer.rdata.count >> 8), UInt8(answer.rdata.count & 0xFF)]
            dns += answer.rdata
        }

        var udp: [UInt8] = []
        udp += [0x00, 0x35]                                  // src port 53
        udp += [0xC0, 0x00]                                  // dst port 49152
        let udpLen = 8 + dns.count
        udp += [UInt8(udpLen >> 8), UInt8(udpLen & 0xFF)]
        udp += [0x00, 0x00]                                  // checksum (unchecked)
        udp += dns

        var ip: [UInt8] = []
        ip += [0x45, 0x00]                                   // v4, ihl 5, tos 0
        let ipLen = 20 + udp.count
        ip += [UInt8(ipLen >> 8), UInt8(ipLen & 0xFF)]
        ip += [0x00, 0x00, 0x00, 0x00]                       // id, flags/frag
        ip += [0x40, 0x11]                                   // ttl 64, proto UDP
        ip += [0x00, 0x00]                                   // checksum (unchecked)
        ip += [8, 8, 8, 8]                                   // src
        ip += [192, 168, 1, 10]                              // dst
        ip += udp

        var eth: [UInt8] = []
        eth += Array(repeating: 0xAA, count: 6)              // dst mac
        eth += Array(repeating: 0xBB, count: 6)              // src mac
        eth += [0x08, 0x00]                                  // IPv4
        eth += ip
        return eth
    }

    func testParsesIPv4Answer() {
        let frame = makeFrame(question: "www.wikipedia.org", answers: [(1, [198, 35, 26, 96])])
        let mappings = DNSParser.mappings(fromFrame: frame, linkType: DNSParser.dltEN10MB)
        XCTAssertEqual(mappings.count, 1)
        XCTAssertEqual(mappings.first?.ip, "198.35.26.96")
        XCTAssertEqual(mappings.first?.host, "www.wikipedia.org")
    }

    func testParsesMultipleAndIPv6() {
        let v6: [UInt8] = [0x26, 0x20, 0x00, 0x00, 0x08, 0x60, 0, 0, 0, 0, 0, 0, 0, 0, 0x88, 0x44]
        let frame = makeFrame(question: "dns.google", answers: [
            (1, [8, 8, 8, 8]),
            (28, v6),
        ])
        let mappings = DNSParser.mappings(fromFrame: frame, linkType: DNSParser.dltEN10MB)
        XCTAssertEqual(mappings.count, 2)
        XCTAssertEqual(mappings[0].ip, "8.8.8.8")
        XCTAssertEqual(mappings[1].ip, "2620:0:860::8844")
        XCTAssertTrue(mappings.allSatisfy { $0.host == "dns.google" })
    }

    func testIgnoresQueries() {
        let frame = makeFrame(question: "example.com", answers: [(1, [93, 184, 216, 34])], qr: false)
        XCTAssertTrue(DNSParser.mappings(fromFrame: frame, linkType: DNSParser.dltEN10MB).isEmpty)
    }

    func testIgnoresNXDomain() {
        let frame = makeFrame(question: "nope.invalid", answers: [], rcode: 3)
        XCTAssertTrue(DNSParser.mappings(fromFrame: frame, linkType: DNSParser.dltEN10MB).isEmpty)
    }

    func testHandlesNullLinkType() {
        var frame = makeFrame(question: "loopback.test", answers: [(1, [127, 0, 0, 1])], qr: true)
        frame.removeFirst(14) // strip Ethernet header
        let nullHeader: [UInt8] = [UInt8(AF_INET), 0, 0, 0] // little-endian AF_INET
        let mappings = DNSParser.mappings(fromFrame: nullHeader + frame, linkType: DNSParser.dltNull)
        XCTAssertEqual(mappings.first?.ip, "127.0.0.1")
        XCTAssertEqual(mappings.first?.host, "loopback.test")
    }

    func testRejectsTruncatedFrame() {
        let frame = makeFrame(question: "trunc.test", answers: [(1, [1, 2, 3, 4])])
        let truncated = Array(frame.prefix(frame.count - 2)) // chop part of rdata
        // Should not crash and should not yield a bogus mapping.
        let mappings = DNSParser.mappings(fromFrame: truncated, linkType: DNSParser.dltEN10MB)
        XCTAssertTrue(mappings.isEmpty)
    }
}
