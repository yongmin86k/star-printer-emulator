import Foundation
import Testing
@testable import StarEmuCore

@Suite struct DiscoveryProtocolTests {
    @Test func answersOnlyStructuredRQ1() {
        #expect(DiscoveryProtocol.shouldAnswer(Fixture.data("protocol/discovery-request-rq1.bin")))
        #expect(!DiscoveryProtocol.shouldAnswer(Fixture.data("protocol/discovery-request-rq4.bin")))
        #expect(!DiscoveryProtocol.shouldAnswer(Data("STR_BCAST".utf8) + Data(count: 503)))   // loose form real printers drop
        #expect(!DiscoveryProtocol.shouldAnswer(Data("hello".utf8)))
    }

    /// The reply the real StarIO10 SDK accepted as an mC-Print3 in Phase 0, with the firmware offsets and byte 0x88
    /// corrected to what both real printers send (protocol-notes §8).
    @Test func replyMatchesSDKAcceptedFixtureByteForByte() {
        let fields = DiscoveryProtocol.ReplyFields(
            shortName: "MCP31L", modelName: "MCP31L (STR-001)", firmware: "V1.0",
            mac: [0x02, 0x53, 0x54, 0x41, 0x52, 0x01],
            ip: "192.168.0.160", netmask: "255.255.255.0", gateway: "192.168.0.1"
        )
        #expect(DiscoveryProtocol.reply(fields) == Fixture.data("protocol/discovery-reply-mcp31l.bin"))
    }

    /// A real TSP100IIIW's reply (2026-10-26) with MAC and IP replaced.
    @Test func tsp100IIIWReplyMatchesRealPrinterByteForByte() {
        let fields = DiscoveryProtocol.ReplyFields(
            shortName: "TSP100LAN", modelName: "TSP143IIIW (STR_T-001)", firmware: "V2.4",
            mac: [0x02, 0x53, 0x54, 0x41, 0x52, 0x01],
            ip: "192.168.0.160", netmask: "255.255.255.0", gateway: "192.168.0.1"
        )
        #expect(DiscoveryProtocol.reply(fields) == Fixture.data("protocol/tsp100iiiw-discovery-reply.bin"))
    }

    @Test func profilesCarryTheirDiscoveryStrings() {
        let tsp = DeviceProfile.tsp100IIIW
        #expect((tsp.modelName, tsp.shortName, tsp.firmware, tsp.displayName) == ("TSP143IIIW (STR_T-001)", "TSP100LAN", "V2.4", "TSP100IIIW"))
        #expect(DeviceProfile.named("tsp100iiiw") == tsp)
        #expect(DeviceProfile.named("mcprint3") == .mcPrint3)
        #expect(DeviceProfile.named("tsp650") == nil)
        #expect(DeviceProfile.all.map(\.id) == ["mcprint3", "tsp100iiiw"])
    }

    @Test func replyPatchesOnlyIdentityFields() {
        let a = DiscoveryProtocol.reply(.init(shortName: "MCP31L", modelName: "MCP31L (STR-001)", firmware: "V1.0",
                                              mac: [2, 0, 0, 0, 0, 1], ip: "10.0.0.5", netmask: "255.255.0.0", gateway: "10.0.0.1"))
        let b = DiscoveryProtocol.reply(.init(shortName: "MCP31L", modelName: "MCP31L (STR-001)", firmware: "V1.0",
                                              mac: [2, 0, 0, 0, 0, 2], ip: "10.0.0.6", netmask: "255.255.0.0", gateway: "10.0.0.1"))
        let differing = zip(a, b).enumerated().filter { $0.element.0 != $0.element.1 }.map(\.offset)
        #expect(differing == [0x53, 0x5B])   // last MAC byte, last IP byte
        #expect(a.count == 302)
    }

    @Test func identityStringsAndPersistence() throws {
        let identity = DeviceIdentity(mac: [0x02, 0x53, 0x54, 0x41, 0x52, 0x01])
        #expect(identity.macString == "02:53:54:41:52:01")
        #expect(identity.sdkIdentifier == "025354415201")
        #expect(DeviceIdentity(macString: "02:53:54:41:52:01") == identity)
        #expect(DeviceIdentity.random().mac[0] & 0x03 == 0x02)   // locally administered unicast

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("identity-\(UUID()).json")
        let first = DeviceIdentity.loadOrCreate(at: url)
        #expect(DeviceIdentity.loadOrCreate(at: url) == first)
    }
}

@Suite struct ASBTests {
    /// Reference frames (THIRD_PARTY_NOTICES.md). Idle/ETB frames match a real TSP100IIIW apart from its bit 2 (§8).
    @Test func referenceFrames() {
        #expect(ASB.frame(faults: FaultState(), etbCounter: 0, etbExecuted: false) == hex("23 86 00 00 00 00 00 00 00 00 00"))
        #expect(ASB.frame(faults: FaultState(coverOpen: true), etbCounter: 2, etbExecuted: false) == hex("23 86 28 00 00 00 00 04 00 00 00"))
        #expect(ASB.frame(faults: FaultState(paperEmpty: true), etbCounter: 2, etbExecuted: false) == hex("23 86 08 00 00 08 00 04 00 00 00"))
        #expect(ASB.frame(faults: FaultState(), etbCounter: 1, etbExecuted: true) == hex("23 86 02 00 00 00 00 02 00 00 00"))
    }

    @Test func etbCounterEncoding() {
        let table: [(Int, UInt8)] = [(0, 0x00), (1, 0x02), (7, 0x0E), (8, 0x20), (15, 0x2E), (16, 0x40), (23, 0x4E), (24, 0x60), (31, 0x6E)]
        for (counter, byte) in table {
            #expect(ASB.encodeETB(counter) == byte)
            #expect(ASB.decodeETB(byte) == counter)
        }
        #expect(ASB.encodeETB(32) == 0x00)
    }
}

@Suite struct PrinterInfoTests {
    /// Frames from a real mC-Print3 (proxy capture, 2026-10-26): idle after `ESC RS E`, and after one ETB.
    @Test func extendedFrameMatchesRealPrinter() {
        #expect(ASB.extendedFrame(faults: FaultState(), etbCounter: 0, etbExecuted: false) == hex("29 8a 04 00 00 00 00 00 00 00 00 06"))
        #expect(ASB.extendedFrame(faults: FaultState(), etbCounter: 1, etbExecuted: true) == hex("29 8a 06 00 00 00 00 02 00 00 00 06"))
    }

    /// The real printer's reply to `ESC GS ) I 01 00 31`, with serial numbers and MAC replaced for this identity.
    @Test func replyMatchesRealPrinterLayoutByteForByte() {
        let identity = DeviceIdentity(mac: [0x02, 0x53, 0x54, 0x41, 0x52, 0x01])
        let status = ASB.extendedFrame(faults: FaultState(), etbCounter: 1, etbExecuted: true)
        #expect(PrinterInfo.reply(identity: identity, status: status) == Fixture.data("protocol/printer-info-reply.bin"))
    }

    @Test func serialIsDerivedFromMAC() {
        #expect(PrinterInfo.serial(for: DeviceIdentity(mac: [0x02, 0x53, 0x54, 0x41, 0x52, 0x01])) == "0002556919108097")
    }
}

@Suite struct StatusEngineTests {
    let session = UUID()

    @Test func statusRequestRepliesWithCurrentFrame() {
        var engine = StatusEngine()
        #expect(engine.handle(.statusRequest, session: session) == hex("23 86 00 00 00 00 00 00 00 00 00"))
    }

    @Test func etbCountsAndClears() {
        var engine = StatusEngine()
        #expect(engine.handle(.etb, session: session) == hex("23 86 02 00 00 00 00 02 00 00 00"))
        _ = engine.handle(.etb, session: session)
        #expect(engine.etbCounter == 2)
        #expect(engine.handle(.clearETB, session: session).isEmpty)
        #expect(engine.handle(.statusRequest, session: session) == hex("23 86 00 00 00 00 00 00 00 00 00"))
    }

    @Test func asbOffIsSilentAsbOnPushesOnChange() {
        var engine = StatusEngine()
        #expect(engine.handle(.asb(enabled: false), session: session).isEmpty)
        #expect(engine.setFaults(FaultState(coverOpen: true)).isEmpty)
        #expect(engine.handle(.asb(enabled: true), session: session).count == 11)
        #expect(engine.setFaults(FaultState()) == [session])
        #expect(engine.setFaults(FaultState()).isEmpty)   // no change, no push
    }

    @Test func statusPortReplyIsTwoFrames() {
        let engine = StatusEngine()
        #expect(engine.statusPortReply.count == 22)
    }

    @Test func printerInfoRequestRepliesForKnownFunctionOnly() {
        var engine = StatusEngine(identity: DeviceIdentity(mac: [0x02, 0x53, 0x54, 0x41, 0x52, 0x01]))
        let reply = engine.handle(.printerInfoRequest(0x31), session: session)
        #expect(reply.prefix(14) == hex("29 8a 04 00 00 00 00 00 00 00 00 06 01 3e"))
        #expect(reply.range(of: Data("LaNmA=025354415201,".utf8)) != nil)
        #expect(engine.handle(.printerInfoRequest(0x33), session: session).isEmpty)   // reply format unknown
    }

    @Test func jobFilter() {
        #expect(!JobAssembler.isJob(Fixture.data("protocol/job-prologue.bin") + hex("00 00 1b 1e 61 00")))
        #expect(JobAssembler.isJob(Fixture.sdk("t-plain")))
        #expect(JobAssembler.isJob(Fixture.sdk("drawer")))
        // A StarGraphic text-only print: the SDK sends an empty document, which is still a print call.
        let empty = Fixture.data("protocol/document-start.bin") + Fixture.data("sdk-tsp100iiiw/t-plain.bin") + Fixture.data("protocol/document-end.bin")
        #expect(JobAssembler.isJob(empty))
    }

    /// Real TSP100IIIW (2026-10-26): answers only `ESC ACK SOH`; idle status 1 has bit 2 set.
    @Test func tsp100IIIWAnswersOnlyStatusRequests() {
        var engine = StatusEngine(profile: .tsp100IIIW)
        #expect(engine.handle(.statusRequest, session: session) == hex("23 86 04 00 00 00 00 00 00 00 00"))
        #expect(engine.handle(.asb(enabled: true), session: session).isEmpty)
        #expect(engine.handle(.clearETB, session: session).isEmpty)
        #expect(engine.handle(.etb, session: session).isEmpty)
        #expect(engine.handle(.statusRequest, session: session) == hex("23 86 06 00 00 00 00 02 00 00 00"))
        _ = engine.handle(.etb, session: session)
        #expect(engine.handle(.statusRequest, session: session) == hex("23 86 06 00 00 00 00 04 00 00 00"))
        #expect(engine.statusPortReply == hex("23 86 06 00 00 00 00 04 00 00 00 23 86 06 00 00 00 00 04 00 00 00"))
    }

    /// Real TSP100IIIW with its cover open (2026-10-26): the paper sensor reads empty too; the SDK reports both.
    @Test func tsp100IIIWCoverOpenAlsoReportsPaperEmpty() {
        var engine = StatusEngine(profile: .tsp100IIIW)
        _ = engine.setFaults(FaultState(coverOpen: true))
        #expect(engine.handle(.statusRequest, session: session) == hex("23 86 2c 00 00 08 00 00 00 00 00"))
        var mc = StatusEngine(profile: .mcPrint3)
        _ = mc.setFaults(FaultState(coverOpen: true))
        #expect(mc.handle(.statusRequest, session: session) == hex("23 86 28 00 00 00 00 00 00 00 00"))   // unchanged
    }
}

@Suite(.timeLimit(.minutes(1)))
struct DiscoveryResponderTests {
    @Test func repliesToRQ1AndIgnoresRQ4() async throws {
        let reply = Data([1, 2, 3])
        let responder = DiscoveryResponder { _ in reply }
        let port = try responder.start(port: 0)
        defer { responder.stop() }

        #expect(await UDPTestClient.exchange(Fixture.data("protocol/discovery-request-rq1.bin"), port: port) == reply)
        #expect(await UDPTestClient.exchange(Fixture.data("protocol/discovery-request-rq4.bin"), port: port) == nil)
    }
}
