import Testing
@testable import Murmur

@Suite("Key name formatting")
struct KeyNamesTests {
    @Test("Known special keys get their glyph")
    func specialKeys() {
        #expect(KeyNames.name(for: UInt16(36)) == "↩")  // Return
        #expect(KeyNames.name(for: UInt16(49)) == "Space")
    }

    @Test("Function keys are recognized")
    func functionKeyDetection() {
        #expect(KeyNames.isFunctionKey(UInt16(122)))  // F1
        #expect(!KeyNames.isFunctionKey(UInt16(0)))  // 'A'
    }

    @Test("Modifier key codes are recognized")
    func modifierKeyDetection() {
        #expect(KeyNames.isModifierKeyCode(UInt16(55)))  // Command
        #expect(!KeyNames.isModifierKeyCode(UInt16(0)))  // 'A'
    }
}
