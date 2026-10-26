import Foundation
import Testing
@testable import StarEmuCore

/// Replays the StarIO10 conversation recorded in Phase 0 against the real listeners (ephemeral ports).
@Suite(.timeLimit(.minutes(1)))
struct PrinterEmulatorTests {
    private func makeEmulator(profile: DeviceProfile = .mcPrint3, faults: FaultState = FaultState()) async throws -> (PrinterEmulator, UInt16, UInt16, UInt16, JobStore) {
        let store = try JobStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("emu-\(UUID())"))
        let config = EmulatorConfig(profile: profile, identity: DeviceIdentity(mac: [2, 0, 0, 0, 0, 1]), printPort: 0, statusPort: 0,
                                    discoveryPort: 0, idleTimeout: .milliseconds(200), faults: faults)
        let emulator = PrinterEmulator(config: config, store: store)
        guard case .started(let p, let s?, let d?) = try await emulator.start() else { throw TestSocket.Failure(description: "no ports") }
        return (emulator, p, s, d, store)
    }

    @Test func sdkPrintSessionGetsStatusRepliesAndOneJob() async throws {
        let (emulator, printPort, _, _, store) = try await makeEmulator()
        var jobs = emulator.jobs.makeAsyncIterator()

        let client = try TCPTestClient(port: printPort)
        client.send(hex("1b 1e 61 00"))                                   // open: ASB off → no reply
        client.send(Fixture.data("protocol/job-prologue.bin"))            // … ESC ACK SOH → 1 frame
        #expect(await client.read(11) == hex("23 86 00 00 00 00 00 00 00 00 00"))

        let document = Fixture.data("protocol/document-start.bin") + Fixture.sdk("receipt") + Fixture.data("protocol/document-end.bin")
        client.send(document)                                             // ETB → frame with counter 1
        #expect(await client.read(11) == hex("23 86 02 00 00 00 00 02 00 00 00"))

        let job = try #require(await jobs.next())                         // finished at document end, not idle
        let stored = try store.data(for: job)
        #expect(stored.range(of: Fixture.sdk("receipt")) != nil)
        #expect(Renderer.render(stored).first?.cut == .partialAfterFeed)

        client.send(hex("00 00 00"))                                      // keep-alives never become jobs
        try await Task.sleep(for: .milliseconds(400))
        #expect(try store.loadAll().count == 1)
        await emulator.stop()
    }

    /// A POS app's open (StarIO10 2.9.1): without a reply the SDK waits ~8 s and gives up (proxy capture, 2026-10-26).
    @Test func printerInfoQueryIsAnswered() async throws {
        let (emulator, printPort, _, _, _) = try await makeEmulator()
        let client = try TCPTestClient(port: printPort)
        client.send(hex("1b 1e 61 00") + Fixture.data("protocol/printer-info-request.bin"))
        let reply = await client.read(332)
        #expect(reply.prefix(14) == hex("29 8a 04 00 00 00 00 00 00 00 00 06 01 3e"))
        #expect(reply.range(of: Data("LaNmA=020000000001,".utf8)) != nil)
        await emulator.stop()
    }

    /// The real TSP100IIIW session (2026-10-26): no frame after ETB, the next status request carries the counter.
    @Test func tsp100IIIWPrintSession() async throws {
        let (emulator, printPort, _, _, store) = try await makeEmulator(profile: .tsp100IIIW)
        var jobs = emulator.jobs.makeAsyncIterator()
        let client = try TCPTestClient(port: printPort)
        client.send(hex("1b 1e 61 00") + Fixture.data("protocol/job-prologue.bin"))
        #expect(await client.read(11) == hex("23 86 04 00 00 00 00 00 00 00 00"))
        client.send(Fixture.data("protocol/document-start.bin") + Fixture.data("sdk-tsp100iiiw/image.bin") + Fixture.data("protocol/document-end.bin"))
        _ = try #require(await jobs.next())
        client.send(hex("1b 06 01"))
        #expect(await client.read(11) == hex("23 86 06 00 00 00 00 02 00 00 00"))   // only one frame: nothing came after ETB
        #expect(try store.loadAll().count == 1)
        await emulator.stop()
    }

    @Test func twoPrintsOnOneConnectionAreTwoJobs() async throws {
        let (emulator, printPort, _, _, store) = try await makeEmulator()
        var jobs = emulator.jobs.makeAsyncIterator()
        let client = try TCPTestClient(port: printPort)
        for name in ["t-plain", "t-bold"] {
            client.send(Fixture.data("protocol/job-prologue.bin"))
            _ = await client.read(11)
            client.send(Fixture.data("protocol/document-start.bin") + Fixture.sdk(name) + Fixture.data("protocol/document-end.bin"))
            _ = await client.read(11)
            _ = try #require(await jobs.next())
        }
        #expect(try store.loadAll().count == 2)
        await emulator.stop()
    }

    @Test func statusPortAnswersAndCloses() async throws {
        let (emulator, _, statusPort, _, _) = try await makeEmulator(faults: FaultState(coverOpen: true))
        let client = try TCPTestClient(port: statusPort)
        client.send(Fixture.data("protocol/status-query-9101.bin"))
        let frame = hex("23 86 28 00 00 00 00 00 00 00 00")
        #expect(await client.read(22) == frame + frame)
        #expect(await client.readEOF())
        await emulator.stop()
    }

    @Test func faultChangesAreVisibleOnNextPoll() async throws {
        let (emulator, _, statusPort, _, _) = try await makeEmulator()
        await emulator.setFaults(FaultState(paperEmpty: true))
        let client = try TCPTestClient(port: statusPort)
        client.send(Fixture.data("protocol/status-query-9101.bin"))
        #expect(await client.read(11) == hex("23 86 08 00 00 08 00 00 00 00 00"))
        await emulator.stop()
    }

    @Test func discoveryAdvertisesTheConfiguredModel() async throws {
        let (emulator, _, _, discoveryPort, _) = try await makeEmulator()
        let reply = try #require(await UDPTestClient.exchange(Fixture.data("protocol/discovery-request-rq1.bin"), port: discoveryPort))
        #expect(reply.count == 302)
        #expect(reply.range(of: Data("MCP31L (STR-001)".utf8)) != nil)
        #expect(reply[0x4E..<0x54] == Data([2, 0, 0, 0, 0, 1]))
        await emulator.stop()
    }
}
