import Foundation

/// Conditions the user can simulate.
public struct FaultState: Sendable, Codable, Equatable {
    public var coverOpen = false
    public var paperEmpty = false
    public var paperNearEnd = false
    public var offline = false

    public init(coverOpen: Bool = false, paperEmpty: Bool = false, paperNearEnd: Bool = false, offline: Bool = false) {
        self.coverOpen = coverOpen
        self.paperEmpty = paperEmpty
        self.paperNearEnd = paperNearEnd
        self.offline = offline
    }

    public var hasError: Bool { coverOpen || paperEmpty || offline }
}

/// Automatic Status Back frame, LAN form (11 bytes). Layout in docs/protocol-notes.md §3.
public enum ASB {
    public static let frameLength = 11

    public static func frame(faults: FaultState, etbCounter: Int, etbExecuted: Bool, idleStatus1: UInt8 = 0) -> Data {
        var status1 = idleStatus1
        if etbExecuted { status1 |= 0x02 }
        if faults.hasError { status1 |= 0x08 }          // offline (derived from any error)
        if faults.coverOpen { status1 |= 0x20 }
        var paper: UInt8 = 0
        if faults.paperNearEnd { paper |= 0x04 }         // UNVERIFIED bit for near end
        if faults.paperEmpty { paper |= 0x08 }
        return Data([0x23, 0x86, status1, 0, 0, paper, 0, encodeETB(etbCounter), 0, 0, 0])
    }

    /// The 12-byte frame a real mC-Print3 sends (header 0x29 encodes 12). Same status/paper/ETB bits as `frame`
    /// (ETB bits match the capture; fault bits UNVERIFIED on this model). The captured printer always sets
    /// status 1 bit 2 and byte 11 = 0x06; meaning UNVERIFIED. Only used in the printer-information reply so far.
    public static func extendedFrame(faults: FaultState, etbCounter: Int, etbExecuted: Bool) -> Data {
        var bytes = [UInt8](frame(faults: faults, etbCounter: etbCounter, etbExecuted: etbExecuted))
        bytes[0] = 0x29
        bytes[1] = 0x8A
        bytes[2] |= 0x04
        return Data(bytes + [0x06])
    }

    /// 5-bit counter scattered over bits 1–3 and 5–6.
    public static func encodeETB(_ counter: Int) -> UInt8 {
        let n = UInt8(counter & 0x1F)
        return ((n & 0x07) << 1) | ((n & 0x18) << 2)
    }

    public static func decodeETB(_ byte: UInt8) -> Int {
        Int(((byte >> 1) & 0x07) | ((byte >> 2) & 0x18))
    }
}

/// Printer-side status state machine: answers status requests and counts ETBs.
public struct StatusEngine: Sendable {
    public private(set) var faults = FaultState()
    public private(set) var etbCounter = 0
    private var etbExecuted = false
    private var asbSessions: Set<UUID> = []
    private let identity: DeviceIdentity
    private let profile: DeviceProfile

    public init(identity: DeviceIdentity = DeviceIdentity(mac: [0x02, 0, 0, 0, 0, 0]), profile: DeviceProfile = .mcPrint3) {
        self.identity = identity
        self.profile = profile
    }

    public var currentFrame: Data {
        ASB.frame(faults: reportedFaults, etbCounter: etbCounter, etbExecuted: etbExecuted, idleStatus1: profile.idleStatus1)
    }

    /// The simulated faults as the printer's sensors would report them.
    private var reportedFaults: FaultState {
        var reported = faults
        if profile.coverOpenHidesPaper, faults.coverOpen { reported.paperEmpty = true }
        return reported
    }

    /// Frame sent unasked (ETB, `ESC RS a 1`); a real TSP100IIIW sends none.
    private var unsolicitedFrame: Data {
        profile.answersOnlyStatusRequests ? Data() : currentFrame
    }

    /// Reply for a TCP/9101 status poll: current + previous state (we only keep current, sent twice).
    public var statusPortReply: Data {
        currentFrame + currentFrame
    }

    /// Returns the bytes to write back on the session for this command (empty = no reply).
    public mutating func handle(_ command: Command, session: UUID) -> Data {
        switch command {
        case .statusRequest:
            return currentFrame
        case .asb(let enabled):
            if enabled { asbSessions.insert(session) } else { asbSessions.remove(session) }
            return enabled ? unsolicitedFrame : Data()
        case .clearETB:
            etbCounter = 0
            etbExecuted = false
            return Data()
        case .etb:
            etbCounter = (etbCounter + 1) % 32
            etbExecuted = true
            return unsolicitedFrame
        case .printerInfoRequest(PrinterInfo.function):
            let status = ASB.extendedFrame(faults: faults, etbCounter: etbCounter, etbExecuted: etbExecuted)
            return PrinterInfo.reply(identity: identity, status: status)
        default:
            return Data()
        }
    }

    /// Changes faults; returns the sessions that asked for automatic status and must get a push.
    public mutating func setFaults(_ new: FaultState) -> Set<UUID> {
        guard new != faults else { return [] }
        faults = new
        return asbSessions
    }

    public mutating func sessionClosed(_ session: UUID) {
        asbSessions.remove(session)
    }
}
