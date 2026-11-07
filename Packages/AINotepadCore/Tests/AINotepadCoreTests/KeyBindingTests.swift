import Foundation
import Testing
@testable import AINotepadCore

@Suite struct KeyBindingTests {
    @Test func displaysSymbolsInMacOrder() {
        #expect(keyBindingDisplay(binding: defaultRecordBinding) == "⌃⌥R")
        #expect(keyBindingDisplay(binding: defaultWindowsBinding) == "⌃⌥P")
        #expect(keyBindingDisplay(binding: KeyBinding(keyCode: 0x31, modifiers: CarbonModifier.command | CarbonModifier.shift)) == "⇧⌘Boşluk")
    }

    // Tuş kapakları: değiştiriciler Mac sırasıyla, sonra tuş; birleşince okunur halle aynı.
    @Test func keyCapsFollowDisplayOrder() {
        let binding: KeyBinding = KeyBinding(keyCode: 0x02, modifiers: CarbonModifier.option | CarbonModifier.control)
        #expect(keyBindingKeyCaps(binding: binding) == ["⌃", "⌥", "D"])
        #expect(keyBindingKeyCaps(binding: binding).joined() == keyBindingDisplay(binding: binding))
        #expect(keyBindingKeyCaps(binding: KeyBinding(keyCode: 0x60, modifiers: 0)) == ["F5"])
    }

    // Yalnızca ⇧ ya da değiştiricisiz harf yazı yazarken tetiklenirdi; işlev tuşları serbest.
    @Test func usableBindingsNeedStrongModifier() {
        #expect(isUsableGlobalBinding(binding: defaultRecordBinding))
        #expect(!isUsableGlobalBinding(binding: KeyBinding(keyCode: 0x0F, modifiers: 0)))
        #expect(!isUsableGlobalBinding(binding: KeyBinding(keyCode: 0x0F, modifiers: CarbonModifier.shift)))
        #expect(isUsableGlobalBinding(binding: KeyBinding(keyCode: 0x60, modifiers: 0)))
        #expect(!isUsableGlobalBinding(binding: KeyBinding(keyCode: 0x7F, modifiers: CarbonModifier.control)))
        #expect(keyEquivalentCharacter(binding: defaultRecordBinding) == "r")
        #expect(keyEquivalentCharacter(binding: KeyBinding(keyCode: 0x60, modifiers: 0)) == nil)
    }
}
