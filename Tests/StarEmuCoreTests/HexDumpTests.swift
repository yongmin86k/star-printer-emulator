import Foundation
import Testing
@testable import StarEmuCore

@Suite struct HexDumpTests {
    @Test func emptyDataIsEmptyString() {
        #expect(HexDump.format(Data()) == "")
    }

    @Test func fullRowAndPartialRow() {
        let data = Data("Hello, StarPRNT!\u{1B}@\n".utf8)
        let expected = """
        00000000  48 65 6c 6c 6f 2c 20 53 74 61 72 50 52 4e 54 21  |Hello, StarPRNT!|
        00000010  1b 40 0a                                         |.@.|
        """
        #expect(HexDump.format(data) == expected)
    }

    @Test func customWidth() {
        let data = Data([0x00, 0x41, 0x7F, 0x80, 0xFF])
        let expected = """
        00000000  00 41 7f 80  |.A..|
        00000004  ff           |.|
        """
        #expect(HexDump.format(data, width: 4) == expected)
    }

    @Test func offsetsAreRelativeToSliceStart() {
        let data = Data([0xAA, 0xBB, 0xCC, 0xDD])
        let slice = data[2...]   // non-zero startIndex
        #expect(HexDump.format(slice, width: 4) == "00000000  cc dd        |..|")
    }
}
