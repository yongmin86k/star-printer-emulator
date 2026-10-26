import Testing
@testable import StarEmuCore

@Suite struct InterfacesTests {
    @Test func loopbackIncludedOnlyWhenAsked() {
        let all = Interfaces.ipv4(includeLoopback: true)
        let lan = Interfaces.ipv4()

        #expect(all.contains { $0.address == "127.0.0.1" })
        #expect(!lan.contains { $0.address.hasPrefix("127.") })
    }

    @Test func addressesAreDottedQuads() {
        for iface in Interfaces.ipv4(includeLoopback: true) {
            let parts = iface.address.split(separator: ".")
            #expect(parts.count == 4)
            #expect(parts.allSatisfy { UInt8($0) != nil })
            #expect(!iface.name.isEmpty)
        }
    }
}
