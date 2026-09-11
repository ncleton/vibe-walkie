import CoreGraphics
import AppKit
import Carbon
import ApplicationServices
import RemoteCore

/// Intègre localement les deltas tant qu'un geste est continu. La position
/// renvoyée par CoreGraphics peut avoir un rafraîchissement de retard juste
/// après `post`; repartir de cette valeur à chaque paquet ferait perdre ou
/// regrouper des mouvements lorsque le téléphone émet à 120 Hz.
struct RelativePointerIntegrator {
    static let continuityInterval: TimeInterval = 0.25

    private(set) var lastPostedLocation: CGPoint?
    private(set) var lastUpdateTime: TimeInterval?

    mutating func target(
        observedLocation: CGPoint,
        deltaX: Double,
        deltaY: Double,
        at time: TimeInterval
    ) -> CGPoint {
        let continuesSyntheticGesture = lastUpdateTime.map {
            time - $0 >= 0 && time - $0 <= Self.continuityInterval
        } ?? false
        let base = continuesSyntheticGesture ? (lastPostedLocation ?? observedLocation) : observedLocation
        let target = CGPoint(x: base.x + deltaX, y: base.y + deltaY)
        lastPostedLocation = target
        lastUpdateTime = time
        return target
    }

    mutating func recordPostedLocation(_ location: CGPoint, at time: TimeInterval) {
        lastPostedLocation = location
        lastUpdateTime = time
    }
}

/// Génération des événements clavier et souris.
///
/// Toutes les entrées viennent d'énumérations fermées ou de valeurs bornées.
/// Les raccourcis matériels sont enregistrés par l'utilisateur sur ce Mac et
/// leurs keycodes sont validés avant exécution. Les coordonnées absolues de
/// l'écran distant sont normalisées et bornées avant conversion.
/// Isolé sur le main actor : `CGEventSource` n'est pas `Sendable` et tous les
/// appelants (routeur de session) vivent déjà sur le main actor.
@MainActor
enum CGEventFactory {

    private static let source = CGEventSource(stateID: .combinedSessionState)
    private static var pointerIntegrator = RelativePointerIntegrator()

    struct PhysicalKeystroke: Equatable {
        let keyCode: CGKeyCode
        let flags: CGEventFlags
    }

    private static var cachedKeyboardLayoutIdentifier: String?
    private static var cachedPhysicalKeystrokes: [String: [PhysicalKeystroke]] = [:]

    // MARK: - Clavier

    private static func keyCode(for key: RemoteKey) -> CGKeyCode {
        switch key {
        case .enter: return 36
        case .escape: return 53
        case .tab, .applicationSwitcher: return 48
        case .nextConversation: return 124
        case .backspace: return 51
        case .delete: return 117
        case .arrowUp: return 126
        case .arrowDown: return 125
        case .arrowLeft: return 123
        case .arrowRight: return 124
        case .space: return 49
        case .copy: return 8
        case .paste: return 9
        case .cut: return 7
        }
    }

    static func press(_ key: RemoteKey, repeatCount: Int = 1) {
        let repeatCount = max(1, repeatCount)
        guard repeatCount > 1 else {
            pressOnce(key)
            return
        }

        for _ in 0..<repeatCount {
            pressOnce(key)
        }
    }

    private static func pressOnce(_ key: RemoteKey) {
        if key == .applicationSwitcher {
            switchToPreviousApplication()
            return
        }
        if key == .nextConversation {
            navigateToNextConversation()
            return
        }
        if key == .copy {
            pressShortcut(keyCode: 8, modifiers: [(55, .maskCommand)])
            return
        }
        if key == .paste {
            pressShortcut(keyCode: 9, modifiers: [(55, .maskCommand)])
            return
        }
        if key == .cut {
            pressShortcut(keyCode: 7, modifiers: [(55, .maskCommand)])
            return
        }

        let code = keyCode(for: key)
        CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true)?.post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)?.post(tap: .cghidEventTap)
    }

    /// Rejoue une combinaison capturée localement dans l'éditeur Mac.
    /// Les valeurs restent bornées par le modèle partagé avant d'atteindre
    /// CoreGraphics.
    static func press(_ shortcut: MacKeyboardShortcut) {
        guard shortcut.isValid else { return }
        let modifiers = shortcut.modifiers.compactMap { modifier -> (CGKeyCode, CGEventFlags)? in
            switch modifier {
            case .command: return (55, .maskCommand)
            case .option: return (58, .maskAlternate)
            case .control: return (59, .maskControl)
            case .shift: return (56, .maskShift)
            case .function: return (63, .maskSecondaryFn)
            case .windows: return (55, .maskCommand)
            case .alt: return (58, .maskAlternate)
            }
        }
        pressShortcut(keyCode: CGKeyCode(shortcut.keyCode), modifiers: modifiers)
    }

    /// Reproduit un appui bref sur Cmd+Tab. Relâcher Command immédiatement
    /// valide la sélection : l'app précédente passe devant sans laisser le
    /// sélecteur macOS affiché.
    private static func switchToPreviousApplication() {
        pressShortcut(keyCode: 48, modifiers: [(55, .maskCommand)])
    }

    /// Utilise le raccourci réellement exposé par l'application active.
    /// ChatGPT possède une commande dédiée « Chat suivant » tandis que Claude
    /// et Chrome suivent la convention macOS Cmd+Option+Flèche droite.
    private static func navigateToNextConversation() {
        let application = NSWorkspace.shared.frontmostApplication
        let bundleIdentifier = application?.bundleIdentifier?.lowercased()
        let applicationName = application?.localizedName?.lowercased()
        let isChatGPT = bundleIdentifier == "com.openai.codex"
            || bundleIdentifier == "com.openai.chat"
            || applicationName == "chatgpt"

        if isChatGPT {
            // Touche physique « ] » sur QWERTY, affichée « $ » sur AZERTY.
            pressShortcut(
                keyCode: 30,
                modifiers: [(55, .maskCommand), (56, .maskShift)]
            )
        } else {
            pressShortcut(
                keyCode: 124,
                modifiers: [(55, .maskCommand), (58, .maskAlternate)]
            )
        }
    }

    /// Envoie les modificateurs comme de vraies touches. Les apps Electron
    /// peuvent ignorer un raccourci si seuls les drapeaux du dernier événement
    /// sont positionnés.
    private static func pressShortcut(
        keyCode: CGKeyCode,
        modifiers: [(keyCode: CGKeyCode, flag: CGEventFlags)]
    ) {
        for modifier in modifiers {
            CGEvent(
                keyboardEventSource: source,
                virtualKey: modifier.keyCode,
                keyDown: true
            )?.post(tap: .cghidEventTap)
        }

        let flags = modifiers.reduce(into: CGEventFlags()) { result, modifier in
            result.insert(modifier.flag)
        }

        if let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true) {
            down.flags = flags
            down.post(tap: .cghidEventTap)
        }
        if let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) {
            up.flags = flags
            up.post(tap: .cghidEventTap)
        }

        for modifier in modifiers.reversed() {
            CGEvent(
                keyboardEventSource: source,
                virtualKey: modifier.keyCode,
                keyDown: false
            )?.post(tap: .cghidEventTap)
        }
    }

    /// Tape du texte par événements Unicode, ou par touches physiques quand
    /// l'application active ne sait pas relayer ces chaînes.
    ///
    /// Découpé en petits paquets : certaines applications ignorent une chaîne
    /// Unicode trop longue attachée à un seul événement.
    @discardableResult
    static func type(_ text: String) -> Bool {
        if requiresPhysicalKeyboardEvents(
            bundleIdentifier: NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        ) {
            return typeUsingPhysicalKeyboardEvents(text)
        }

        return typeUsingUnicodeEvents(text)
    }

    /// Partage d’écran ne transporte pas la chaîne Unicode attachée à un
    /// `CGEvent`. Il ne transmet que son code de touche physique. Comme la
    /// frappe Unicode utilise historiquement le code 0, un clavier AZERTY
    /// distant reçoit alors uniquement des « q ». Dans ce cas précis, on
    /// traduit le texte en vraies touches de la disposition active.
    static func requiresPhysicalKeyboardEvents(bundleIdentifier: String?) -> Bool {
        bundleIdentifier?.lowercased() == "com.apple.screensharing"
    }

    static func physicalKeystrokes(for text: String) -> [PhysicalKeystroke]? {
        let normalizedText = text.precomposedStringWithCanonicalMapping
        guard !normalizedText.isEmpty else { return [] }

        let keyMap = currentPhysicalKeystrokeMap()
        var result: [PhysicalKeystroke] = []
        result.reserveCapacity(normalizedText.count)

        for character in normalizedText {
            switch character {
            case "\n", "\r":
                result.append(PhysicalKeystroke(keyCode: 36, flags: []))
            case "\t":
                result.append(PhysicalKeystroke(keyCode: 48, flags: []))
            default:
                guard let strokes = keyMap[String(character)] else { return nil }
                result.append(contentsOf: strokes)
            }
        }
        return result
    }

    private static func typeUsingUnicodeEvents(_ text: String) -> Bool {
        for chunk in text.chunked(by: 16) {
            let utf16 = Array(chunk.utf16)
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { return false }
            down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
            up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
        return true
    }

    private static func typeUsingPhysicalKeyboardEvents(_ text: String) -> Bool {
        // Revenir à l'événement Unicode avec son keycode 0 recréerait
        // précisément le « q » parasite dans Partage d'écran. Un caractère
        // sans équivalent physique est donc refusé proprement.
        guard let strokes = physicalKeystrokes(for: text) else { return false }

        for stroke in strokes {
            guard post(stroke) else { return false }
        }
        return true
    }

    private static func post(_ stroke: PhysicalKeystroke) -> Bool {
        guard let down = CGEvent(
            keyboardEventSource: source,
            virtualKey: stroke.keyCode,
            keyDown: true
        ), let up = CGEvent(
            keyboardEventSource: source,
            virtualKey: stroke.keyCode,
            keyDown: false
        ) else { return false }

        let modifiers: [(keyCode: CGKeyCode, flag: CGEventFlags)] = [
            (56, .maskShift),
            (58, .maskAlternate)
        ].filter { stroke.flags.contains($0.flag) }

        for modifier in modifiers {
            CGEvent(
                keyboardEventSource: source,
                virtualKey: modifier.keyCode,
                keyDown: true
            )?.post(tap: .cghidEventTap)
        }

        down.flags = stroke.flags
        up.flags = stroke.flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)

        for modifier in modifiers.reversed() {
            CGEvent(
                keyboardEventSource: source,
                virtualKey: modifier.keyCode,
                keyDown: false
            )?.post(tap: .cghidEventTap)
        }
        return true
    }

    private static func currentPhysicalKeystrokeMap() -> [String: [PhysicalKeystroke]] {
        let inputSource = TISCopyCurrentKeyboardLayoutInputSource().takeRetainedValue()
        let identifier = inputSourceIdentifier(inputSource)
        if identifier == cachedKeyboardLayoutIdentifier, !cachedPhysicalKeystrokes.isEmpty {
            return cachedPhysicalKeystrokes
        }

        guard let rawLayoutData = TISGetInputSourceProperty(
            inputSource,
            kTISPropertyUnicodeKeyLayoutData
        ) else { return [:] }
        let layoutData = unsafeBitCast(rawLayoutData, to: CFData.self)
        guard let bytes = CFDataGetBytePtr(layoutData) else { return [:] }
        let keyboardLayout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)

        let modifierStates: [(carbon: UInt32, flags: CGEventFlags)] = [
            (0, []),
            (UInt32(shiftKey >> 8), .maskShift),
            (UInt32(optionKey >> 8), .maskAlternate),
            (UInt32((shiftKey | optionKey) >> 8), [.maskShift, .maskAlternate])
        ]
        let candidates = modifierStates.flatMap { modifier in
            (UInt16(0)..<UInt16(128)).map { keyCode in
                (
                    keyCode: keyCode,
                    carbonModifiers: modifier.carbon,
                    stroke: PhysicalKeystroke(
                        keyCode: CGKeyCode(keyCode),
                        flags: modifier.flags
                    )
                )
            }
        }
        var map: [String: [PhysicalKeystroke]] = [:]
        var deadKeyPrefixes: [(stroke: PhysicalKeystroke, state: UInt32)] = []

        for candidate in candidates {
            var deadKeyState: UInt32 = 0
            guard let output = translatedOutput(
                keyboardLayout: keyboardLayout,
                keyCode: candidate.keyCode,
                modifiers: candidate.carbonModifiers,
                deadKeyState: &deadKeyState
            ) else { continue }
            if output.isEmpty, deadKeyState != 0 {
                deadKeyPrefixes.append((candidate.stroke, deadKeyState))
            } else if output.count == 1, map[output] == nil {
                map[output] = [candidate.stroke]
            }
        }

        // Les caractères fréquents de dictée tels que « ê », « ô » ou « ï »
        // sont produits par une touche morte suivie d'une lettre. Screen
        // Sharing ne transporte que ces touches physiques, donc on conserve
        // aussi leurs séquences, pas uniquement les caractères directs.
        for prefix in deadKeyPrefixes {
            for candidate in candidates {
                var deadKeyState = prefix.state
                guard let output = translatedOutput(
                    keyboardLayout: keyboardLayout,
                    keyCode: candidate.keyCode,
                    modifiers: candidate.carbonModifiers,
                    deadKeyState: &deadKeyState
                ), output.count == 1, map[output] == nil else { continue }
                map[output] = [prefix.stroke, candidate.stroke]
            }
        }

        cachedKeyboardLayoutIdentifier = identifier
        cachedPhysicalKeystrokes = map
        return map
    }

    private static func translatedOutput(
        keyboardLayout: UnsafePointer<UCKeyboardLayout>,
        keyCode: UInt16,
        modifiers: UInt32,
        deadKeyState: inout UInt32
    ) -> String? {
        var characters = [UniChar](repeating: 0, count: 8)
        var characterCount = 0
        let status = UCKeyTranslate(
            keyboardLayout,
            keyCode,
            UInt16(kUCKeyActionDown),
            modifiers,
            UInt32(LMGetKbdType()),
            0,
            &deadKeyState,
            characters.count,
            &characterCount,
            &characters
        )
        guard status == noErr else { return nil }
        return String(
            utf16CodeUnits: characters,
            count: characterCount
        ).precomposedStringWithCanonicalMapping
    }

    private static func inputSourceIdentifier(_ inputSource: TISInputSource) -> String {
        guard let rawIdentifier = TISGetInputSourceProperty(
            inputSource,
            kTISPropertyInputSourceID
        ) else { return "unknown" }
        return unsafeBitCast(rawIdentifier, to: CFString.self) as String
    }

    /// Colle avec un vrai Cmd+V.
    ///
    /// Les quatre événements sont envoyés séparément avec le drapeau command
    /// sur les deux touches V : un raccourci simulé partiellement est ignoré
    /// par plusieurs applications Electron.
    static func paste() {
        let command: CGKeyCode = 55
        let v: CGKeyCode = 9

        CGEvent(keyboardEventSource: source, virtualKey: command, keyDown: true)?.post(tap: .cghidEventTap)

        if let down = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: true) {
            down.flags = .maskCommand
            down.post(tap: .cghidEventTap)
        }
        if let up = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: false) {
            up.flags = .maskCommand
            up.post(tap: .cghidEventTap)
        }

        CGEvent(keyboardEventSource: source, virtualKey: command, keyDown: false)?.post(tap: .cghidEventTap)
    }

    // MARK: - Pointeur

    private static var currentLocation: CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    /// Déplace le curseur d'un delta, en le gardant sur un écran connecté.
    static func move(deltaX: Double, deltaY: Double) {
        let now = ProcessInfo.processInfo.systemUptime
        let target = clampToScreens(pointerIntegrator.target(
            observedLocation: currentLocation,
            deltaX: deltaX,
            deltaY: deltaY,
            at: now
        ))
        pointerIntegrator.recordPostedLocation(target, at: now)
        let event = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: target, mouseButton: .left)
        event?.post(tap: .cghidEventTap)
    }

    static func moveAbsolute(normalizedX: Double, normalizedY: Double) {
        let bounds = CGDisplayBounds(CGMainDisplayID())
        let x = min(max(normalizedX, 0), 1)
        let y = min(max(normalizedY, 0), 1)
        let target = CGPoint(
            x: bounds.minX + x * bounds.width,
            y: bounds.minY + y * bounds.height
        )
        pointerIntegrator.recordPostedLocation(target, at: ProcessInfo.processInfo.systemUptime)
        CGEvent(
            mouseEventSource: source,
            mouseType: .mouseMoved,
            mouseCursorPosition: target,
            mouseButton: .left
        )?.post(tap: .cghidEventTap)
    }

    static func click(button: PointerButton, clickCount: Int) {
        let location = currentLocation
        let count = ControlInputPolicy.clickCount(clickCount)
        let (down, up, cgButton): (CGEventType, CGEventType, CGMouseButton) = button == .left
            ? (.leftMouseDown, .leftMouseUp, .left)
            : (.rightMouseDown, .rightMouseUp, .right)

        for index in 1...count {
            if let event = CGEvent(mouseEventSource: source, mouseType: down, mouseCursorPosition: location, mouseButton: cgButton) {
                event.setIntegerValueField(.mouseEventClickState, value: Int64(index))
                event.post(tap: .cghidEventTap)
            }
            if let event = CGEvent(mouseEventSource: source, mouseType: up, mouseCursorPosition: location, mouseButton: cgButton) {
                event.setIntegerValueField(.mouseEventClickState, value: Int64(index))
                event.post(tap: .cghidEventTap)
            }
        }
    }

    static func drag(phase: DragPhase, deltaX: Double, deltaY: Double) {
        let now = ProcessInfo.processInfo.systemUptime
        let target = clampToScreens(pointerIntegrator.target(
            observedLocation: currentLocation,
            deltaX: deltaX,
            deltaY: deltaY,
            at: now
        ))
        pointerIntegrator.recordPostedLocation(target, at: now)
        let type: CGEventType
        switch phase {
        case .began: type = .leftMouseDown
        case .moved: type = .leftMouseDragged
        case .ended: type = .leftMouseUp
        }
        CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: target, mouseButton: .left)?
            .post(tap: .cghidEventTap)
    }

    static func scroll(deltaX: Double, deltaY: Double) {
        let event = CGEvent(
            scrollWheelEvent2Source: source,
            units: .pixel,
            wheelCount: 2,
            wheel1: Int32(clamping: Int(deltaY)),
            wheel2: Int32(clamping: Int(deltaX)),
            wheel3: 0
        )
        event?.post(tap: .cghidEventTap)
    }

    /// Figma documente le zoom à la souris comme Command + molette. Cette
    /// forme fonctionne aussi dans ses vues Electron, contrairement à un
    /// simple drapeau posé sans événement de touche Command réel.
    static func zoom(deltaY: Double) {
        let wheelDelta = Int32(clamping: Int(deltaY.rounded()))
        guard wheelDelta != 0 else { return }

        let command: CGKeyCode = 55
        CGEvent(keyboardEventSource: source, virtualKey: command, keyDown: true)?
            .post(tap: .cghidEventTap)

        if let event = CGEvent(
            scrollWheelEvent2Source: source,
            units: .pixel,
            wheelCount: 1,
            wheel1: wheelDelta,
            wheel2: 0,
            wheel3: 0
        ) {
            event.flags = .maskCommand
            event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            event.post(tap: .cghidEventTap)
        }

        CGEvent(keyboardEventSource: source, virtualKey: command, keyDown: false)?
            .post(tap: .cghidEventTap)
    }

    /// La nouvelle app ChatGPT expose Voice via une commande clavier stable,
    /// même lorsque sa fenêtre Chromium n'est pas encore publiée dans l'arbre
    /// d'accessibilité. `Ctrl+Shift+V` est le raccourci macOS par défaut de la
    /// commande interne `composer.startVoiceMode`.
    static func toggleChatGPTVoiceMode() {
        pressShortcut(
            keyCode: 9,
            modifiers: [(59, .maskControl), (56, .maskShift)]
        )
    }

    /// Certains contrôles Chromium annoncent `AXPress` et renvoient même un
    /// succès sans déclencher leur gestionnaire JavaScript. Un clic HID au
    /// centre des bornes AX traverse alors le même chemin qu'un vrai clic.
    /// Chromium traite ces événements de façon asynchrone. Le pointeur reste
    /// donc sur la cible : une restauration, même différée, peut encore faire
    /// retraiter le clic à l'ancienne position et fermer le chat vocal.
    @discardableResult
    static func click(at point: CGPoint, settlingDelay: TimeInterval = 0.10) -> Bool {
        let target = clampToScreens(point)

        guard let move = CGEvent(
            mouseEventSource: source,
            mouseType: .mouseMoved,
            mouseCursorPosition: target,
            mouseButton: .left
        ), let down = CGEvent(
            mouseEventSource: source,
            mouseType: .leftMouseDown,
            mouseCursorPosition: target,
            mouseButton: .left
        ), let up = CGEvent(
            mouseEventSource: source,
            mouseType: .leftMouseUp,
            mouseCursorPosition: target,
            mouseButton: .left
        ) else { return false }

        move.post(tap: .cghidEventTap)
        if settlingDelay > 0 {
            Thread.sleep(forTimeInterval: settlingDelay)
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    /// Garde le curseur dans l'union des écrans branchés.
    private static func clampToScreens(_ point: CGPoint) -> CGPoint {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return point }

        if screens.contains(where: { $0.frame.contains(point) }) {
            return point
        }
        let union = screens.reduce(CGRect.null) { $0.union($1.frame) }
        return CGPoint(
            x: min(max(point.x, union.minX), union.maxX - 1),
            y: min(max(point.y, union.minY), union.maxY - 1)
        )
    }
}

/// Politique pure et testable qui limite les clics aux libellés vocaux connus.
/// Les correspondances volontairement spécifiques évitent qu'une commande
/// distante ne presse un autre bouton de ChatGPT ou Claude par accident.
enum AIVoiceControlLabelPolicy {
    static func beganScore(for label: String) -> Int? {
        let label = normalized(label)
        // « désactiver » contient « activer ». Sans cette exclusion, un micro
        // déjà ouvert est pris pour un micro coupé puis immédiatement muté.
        if containsAny(label, [
            "desactiver le microphone", "desactiver le micro"
        ]) {
            return nil
        }
        if containsAny(label, [
            "unmute microphone", "unmute mic", "reactiver le microphone",
            "reactiver le micro", "activer le microphone", "activer le micro"
        ]) {
            return 0
        }
        if containsAny(label, [
            "start voice chat", "start voice conversation", "start voice mode",
            "start a new voice chat", "start new voice chat",
            "demarrer une conversation vocale", "demarrer le chat vocal",
            "demarrer un nouveau chat vocal", "nouveau chat vocal",
            "demarrer le mode vocal", "voice mode", "mode vocal"
        ]) {
            return 1
        }
        return nil
    }

    static func endedScore(for label: String) -> Int? {
        let label = normalized(label)
        // Réciproquement, « unmute » contient « mute » et « réactiver »
        // contient « activer ». Ces libellés décrivent un micro déjà coupé :
        // ils ne doivent jamais être interprétés comme l'action de le couper.
        let isExplicitlyMuted = containsAny(label, [
            "unmute microphone", "unmute mic", "reactiver le microphone",
            "reactiver le micro"
        ]) || (
            containsAny(label, ["activer le microphone", "activer le micro"])
                && !containsAny(label, ["desactiver le microphone", "desactiver le micro"])
        )
        if isExplicitlyMuted {
            return nil
        }
        if containsAny(label, [
            "mute microphone", "mute mic", "couper le microphone", "couper le micro",
            "desactiver le microphone", "desactiver le micro",
            "mettre le microphone en sourdine", "mettre le micro en sourdine"
        ]) {
            return 0
        }
        if containsAny(label, [
            "end voice chat", "stop voice chat", "end voice conversation",
            "stop voice conversation", "end voice mode", "stop voice mode",
            "arreter la conversation vocale", "terminer la conversation vocale",
            "quitter le mode vocal", "arreter le mode vocal"
        ]) {
            return 1
        }
        return nil
    }

    private static func normalized(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "fr_FR")
        )
    }

    private static func containsAny(_ value: String, _ candidates: [String]) -> Bool {
        candidates.contains(where: value.contains)
    }
}

/// Actionne uniquement les contrôles vocaux visibles des applications
/// officielles. Aucun son ni texte ne traverse ce chemin : le microphone et
/// la session restent entièrement gérés par l'application sur le Mac.
@MainActor
enum AIVoiceModeAutomation {
    private struct CachedMicrophoneControl {
        let processIdentifier: pid_t
        let element: AXUIElement
    }

    /// Les versions récentes de ChatGPT placent le bouton vocal dans une
    /// AXWebArea profondément imbriquée. Une conversation longue peut aussi
    /// contenir des milliers d'éléments : une limite trop basse arrêtait la
    /// recherche avant d'atteindre le contrôle « Mode vocal » de la barre
    /// latérale.
    private static let maximumTraversalDepth = 32
    private static let maximumTraversalCount = 6_000
    /// Les contrôles de la session Voice ChatGPT apparaissent actuellement
    /// dans les premiers centaines d'éléments. Parcourir ensuite tout le fil
    /// Codex (qui peut contenir des milliers de lignes de diagnostic) retarde
    /// inutilement le raccourci jusqu'après le relâchement du bouton.
    private static let maximumUnifiedChatGPTTraversalCount = 2_500
    private static var requestedListening: [VoiceAssistantProvider: Bool] = [:]
    private static var retryTasks: [VoiceAssistantProvider: Task<Void, Never>] = [:]
    private static var cachedMicrophoneControls: [VoiceAssistantProvider: CachedMicrophoneControl] = [:]
    private static var chatGPTVoiceLaunchPending = false

    static func handle(_ payload: VoiceControlPayload) {
        let listening = payload.phase == .began
        requestedListening[payload.provider] = listening
        retryTasks[payload.provider]?.cancel()
        if payload.provider == .chatGPT {
            chatGPTVoiceLaunchPending = false
        }

        if perform(provider: payload.provider, listening: listening) {
            return
        }
        scheduleRetry(provider: payload.provider, listening: listening, attempt: 1)
    }

    private static func scheduleRetry(
        provider: VoiceAssistantProvider,
        listening: Bool,
        attempt: Int
    ) {
        guard attempt <= 8 else { return }
        retryTasks[provider] = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(220 * attempt))
            guard !Task.isCancelled, requestedListening[provider] == listening else { return }
            if !perform(provider: provider, listening: listening) {
                scheduleRetry(provider: provider, listening: listening, attempt: attempt + 1)
            }
        }
    }

    private static func perform(provider: VoiceAssistantProvider, listening: Bool) -> Bool {
        guard let application = application(for: provider, activate: listening) else {
            if listening { launch(provider) }
            NSLog("[VibeWalkie] voice_control_application_not_running provider=%@", provider.rawValue)
            return false
        }

        let root = AXUIElementCreateApplication(application.processIdentifier)
        // Electron/Chromium peut laisser son arbre web désactivé pour un
        // client AX direct, alors que System Events le rend visible. Cet
        // attribut documenté par Electron force la publication de l'arbre ;
        // les tentatives suivantes laissent le temps au renderer de répondre.
        _ = AXUIElementSetAttributeValue(
            root,
            "AXManualAccessibility" as CFString,
            kCFBooleanTrue
        )

        // Une fois la session vocale ouverte, le même toggle sert à chaque
        // appui PTT. Le réutiliser évite de reparcourir tout l'arbre Chromium
        // avant chaque phrase, et ouvre ainsi le micro presque au toucher.
        if let cached = cachedMicrophoneControls[provider],
           cached.processIdentifier == application.processIdentifier,
           applyCachedMicrophoneControl(
               cached.element,
               provider: provider,
               application: application,
               listening: listening
           ) {
            return true
        }
        cachedMicrophoneControls[provider] = nil

        let isUnifiedChatGPT = provider == .chatGPT
            && application.bundleIdentifier?.lowercased() == "com.openai.codex"
        let elements = descendants(
            of: root,
            maximumCount: isUnifiedChatGPT
                ? maximumUnifiedChatGPTTraversalCount
                : maximumTraversalCount
        )

        if listening {
            // Quand une session existe déjà, le contrôle micro est beaucoup
            // plus précis que « nouveau chat vocal » encore visible dans la
            // barre latérale : on réactive le micro s'il est coupé, sinon on
            // considère que l'écoute est déjà effective.
            let microphoneControls = elements.compactMap { element -> (AXUIElement, Int)? in
                guard isMicrophoneControl(element, in: application) else { return nil }
                let label = accessibleLabel(of: element)
                guard supportsPressAction(element) else { return nil }
                if AIVoiceControlLabelPolicy.beganScore(for: label) == 0 {
                    return (element, 0)
                }
                if AIVoiceControlLabelPolicy.endedScore(for: label) == 0 {
                    return (element, 1)
                }
                return nil
            }
            .sorted { $0.1 < $1.1 }

            if let (control, state) = microphoneControls.first {
                cacheMicrophoneControl(control, provider: provider, application: application)
                if state == 1 {
                    chatGPTVoiceLaunchPending = false
                    NSLog(
                        "[VibeWalkie] voice_control_already_listening provider=%@",
                        provider.rawValue
                    )
                    return true
                }
                if pressMicrophoneControl(control) {
                    chatGPTVoiceLaunchPending = false
                    NSLog(
                        "[VibeWalkie] voice_control_microphone_unmuted provider=%@",
                        provider.rawValue
                    )
                    return true
                }
            }

            // Depuis l'app ChatGPT unifiée, Voice possède un raccourci natif
            // alors que le bouton peut être totalement absent de l'arbre AX
            // tant que la première session n'a pas démarré. Attendre que
            // l'application soit réellement active empêche d'envoyer la
            // combinaison à l'app précédemment au premier plan.
            if isUnifiedChatGPT {
                guard application.isActive
                    || NSWorkspace.shared.frontmostApplication?.processIdentifier
                        == application.processIdentifier else { return false }
                if !chatGPTVoiceLaunchPending {
                    chatGPTVoiceLaunchPending = true
                    // Le bouton visible reste fiable même lorsque ChatGPT
                    // ignore temporairement son raccourci après plusieurs
                    // sessions Voice rapprochées. Sa taille et son rôle
                    // éliminent les lignes de transcript qui répètent le
                    // même libellé dans l'app unifiée.
                    if let startButton = elements.first(where: { element in
                        AIVoiceControlLabelPolicy.beganScore(
                            for: accessibleLabel(of: element)
                        ) == 1
                            && supportsPressAction(element)
                            && isVisibleUnifiedVoiceStartButton(element)
                    }), pressMicrophoneControl(startButton) {
                        NSLog(
                            "[VibeWalkie] voice_control_visible_start_clicked provider=%@",
                            provider.rawValue
                        )
                    } else {
                        CGEventFactory.toggleChatGPTVoiceMode()
                        NSLog(
                            "[VibeWalkie] voice_control_shortcut_sent provider=%@",
                            provider.rawValue
                        )
                    }

                    // Le renderer Voice est un autre processus Chromium. Il
                    // lui faut quelques instants pour publier son toggle AX ;
                    // le relire ici rend le premier appui déterministe, même
                    // si les tâches de retry sont retardées par une longue
                    // conversation en cours de rendu.
                    for delay in [3.8, 1.2] {
                        Thread.sleep(forTimeInterval: delay)
                        let refreshedElements = descendants(
                            of: root,
                            maximumCount: maximumUnifiedChatGPTTraversalCount
                        )
                        let refreshedMicrophones = refreshedElements.compactMap {
                            element -> (AXUIElement, Int)? in
                            guard isMicrophoneControl(element, in: application) else {
                                return nil
                            }
                            let label = accessibleLabel(of: element)
                            guard supportsPressAction(element) else { return nil }
                            if AIVoiceControlLabelPolicy.beganScore(for: label) == 0 {
                                return (element, 0)
                            }
                            if AIVoiceControlLabelPolicy.endedScore(for: label) == 0 {
                                return (element, 1)
                            }
                            return nil
                        }
                        .sorted { $0.1 < $1.1 }

                        if let (control, state) = refreshedMicrophones.first {
                            cacheMicrophoneControl(control, provider: provider, application: application)
                            if state == 1 {
                                chatGPTVoiceLaunchPending = false
                                return true
                            }
                            if pressMicrophoneControl(control) {
                                chatGPTVoiceLaunchPending = false
                                NSLog(
                                    "[VibeWalkie] voice_control_post_launch_unmuted provider=%@",
                                    provider.rawValue
                                )
                                return true
                            }
                        }
                    }
                }
                // L'ouverture est asynchrone et ChatGPT peut mémoriser un
                // micro coupé entre deux sessions. Continuer les tentatives
                // jusqu'à voir le toggle permet alors de le réactiver.
                return false
            }
        }

        if !listening,
           let microphoneControl = elements.first(where: { element in
               guard isMicrophoneControl(element, in: application) else { return false }
               return AIVoiceControlLabelPolicy.endedScore(
                   for: accessibleLabel(of: element)
               ) == 0 && supportsPressAction(element)
           }),
           pressMicrophoneControl(microphoneControl) {
            cacheMicrophoneControl(
                microphoneControl,
                provider: provider,
                application: application
            )
            NSLog(
                "[VibeWalkie] voice_control_microphone_muted provider=%@",
                provider.rawValue
            )
            return true
        }

        // Dans l'app ChatGPT/Codex unifiée, un relâchement PTT ne doit agir
        // que sur le véritable toggle micro ci-dessus. Le transcript, les
        // tâches de la barre latérale et certaines commandes de partage
        // d'écran peuvent exposer de petits boutons dont le libellé agrégé
        // répète « arrêter le chat vocal ». Cliquer l'un d'eux serait pire
        // que de ne rien faire quand aucune session Voice n'est ouverte.
        if !listening, isUnifiedChatGPT {
            NSLog(
                "[VibeWalkie] voice_control_no_microphone_to_mute provider=%@",
                provider.rawValue
            )
            return true
        }

        let scoredButtons = elements.compactMap { element -> (AXUIElement, Int)? in
            let label = accessibleLabel(of: element)
            let score = listening
                ? AIVoiceControlLabelPolicy.beganScore(for: label)
                : AIVoiceControlLabelPolicy.endedScore(for: label)
            guard let score, supportsPressAction(element) else { return nil }
            if score == 0, !isMicrophoneControl(element, in: application) {
                return nil
            }
            return (element, score)
        }
        .sorted { $0.1 < $1.1 }

        for (button, score) in scoredButtons {
            let pressed = !listening && score == 0
                ? pressMicrophoneControl(button)
                : AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
            if pressed {
                NSLog(
                    "[VibeWalkie] voice_control_button_pressed provider=%@ listening=%@",
                    provider.rawValue,
                    listening ? "true" : "false"
                )
                return true
            }
        }
        NSLog(
            "[VibeWalkie] voice_control_button_not_found provider=%@ listening=%@ elements=%ld candidates=%ld",
            provider.rawValue,
            listening ? "true" : "false",
            elements.count,
            scoredButtons.count
        )
        return false
    }

    private static func application(
        for provider: VoiceAssistantProvider,
        activate: Bool
    ) -> NSRunningApplication? {
        for bundleIdentifier in bundleIdentifiers(for: provider) {
            if let application = NSRunningApplication.runningApplications(
                withBundleIdentifier: bundleIdentifier
            ).first {
                if activate {
                    application.unhide()
                    application.activate(options: [.activateAllWindows])
                    if let url = application.bundleURL {
                        let configuration = NSWorkspace.OpenConfiguration()
                        configuration.activates = true
                        NSWorkspace.shared.openApplication(
                            at: url,
                            configuration: configuration
                        ) { _, _ in }
                    }
                }
                return application
            }
        }
        return nil
    }

    private static func launch(_ provider: VoiceAssistantProvider) {
        for bundleIdentifier in bundleIdentifiers(for: provider) {
            guard let url = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: bundleIdentifier
            ) else { continue }
            NSWorkspace.shared.openApplication(
                at: url,
                configuration: NSWorkspace.OpenConfiguration()
            ) { _, _ in }
            return
        }
    }

    private static func bundleIdentifiers(for provider: VoiceAssistantProvider) -> [String] {
        switch provider {
        case .chatGPT:
            ["com.openai.codex", "com.openai.chat", "com.openai.chatgpt"]
        case .claude:
            ["com.anthropic.claudefordesktop"]
        }
    }

    private static func descendants(
        of root: AXUIElement,
        maximumCount: Int
    ) -> [AXUIElement] {
        var result: [AXUIElement] = []
        var pending: [(AXUIElement, Int)] = [(root, 0)]
        var nextIndex = 0

        // Parcours en largeur : les contrôles de navigation restent proches
        // de la fenêtre, tandis que le contenu d'une longue conversation peut
        // remplir à lui seul des milliers de descendants dans une première
        // branche. Le précédent parcours en profondeur n'atteignait alors
        // jamais le bouton vocal.
        while nextIndex < pending.count, result.count < maximumCount {
            let (element, depth) = pending[nextIndex]
            nextIndex += 1
            result.append(element)
            guard depth < maximumTraversalDepth else { continue }
            for child in children(of: element) {
                pending.append((child, depth + 1))
            }
        }
        return result
    }

    private static func supportsPressAction(_ element: AXUIElement) -> Bool {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success,
              let actions = names as? [String] else { return false }
        return actions.contains(kAXPressAction as String)
    }

    private static func cacheMicrophoneControl(
        _ element: AXUIElement,
        provider: VoiceAssistantProvider,
        application: NSRunningApplication
    ) {
        cachedMicrophoneControls[provider] = CachedMicrophoneControl(
            processIdentifier: application.processIdentifier,
            element: element
        )
    }

    private static func applyCachedMicrophoneControl(
        _ element: AXUIElement,
        provider: VoiceAssistantProvider,
        application: NSRunningApplication,
        listening: Bool
    ) -> Bool {
        guard isMicrophoneControl(element, in: application),
              supportsPressAction(element) else { return false }

        let label = accessibleLabel(of: element)
        if listening {
            if AIVoiceControlLabelPolicy.endedScore(for: label) == 0 {
                NSLog("[VibeWalkie] voice_control_cached_already_listening provider=%@", provider.rawValue)
                return true
            }
            guard AIVoiceControlLabelPolicy.beganScore(for: label) == 0,
                  pressMicrophoneControl(element, settlingDelay: 0.02) else { return false }
            NSLog("[VibeWalkie] voice_control_cached_unmuted provider=%@", provider.rawValue)
            return true
        }

        if AIVoiceControlLabelPolicy.beganScore(for: label) == 0 {
            return true
        }
        guard AIVoiceControlLabelPolicy.endedScore(for: label) == 0,
              pressMicrophoneControl(element, settlingDelay: 0.02) else { return false }
        NSLog("[VibeWalkie] voice_control_cached_muted provider=%@", provider.rawValue)
        return true
    }

    /// Préfère le clic physique pour le micro ChatGPT : sur sa case à cocher
    /// Chromium, `AXUIElementPerformAction(.press)` renvoie `.success` mais ne
    /// change pas l'état. Les autres applications conservent AXPress comme
    /// repli si les bornes ne sont pas disponibles.
    private static func pressMicrophoneControl(
        _ element: AXUIElement,
        settlingDelay: TimeInterval = 0.10
    ) -> Bool {
        if let point = center(of: element),
           CGEventFactory.click(at: point, settlingDelay: settlingDelay) {
            return true
        }
        return AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
    }

    /// L'app ChatGPT unifiée contient aussi l'interface Codex et donc le texte
    /// des diagnostics en cours. Certains conteneurs de ce texte sont eux-mêmes
    /// pressables et peuvent contenir « activer le microphone ». Le vrai micro
    /// vocal est, lui, publié sans ambiguïté comme case à cocher basculante.
    private static func isMicrophoneControl(
        _ element: AXUIElement,
        in application: NSRunningApplication
    ) -> Bool {
        guard application.bundleIdentifier?.lowercased() == "com.openai.codex" else {
            return true
        }
        return role(of: element) == kAXCheckBoxRole as String
            && subrole(of: element) == "AXToggleButton"
    }

    private static func isVisibleUnifiedVoiceStartButton(_ element: AXUIElement) -> Bool {
        guard role(of: element) == kAXButtonRole as String,
              let rawSize = attribute(kAXSizeAttribute as CFString, of: element),
              CFGetTypeID(rawSize) == AXValueGetTypeID() else { return false }
        let sizeValue = unsafeBitCast(rawSize, to: AXValue.self)
        var size = CGSize.zero
        guard AXValueGetValue(sizeValue, .cgSize, &size) else { return false }
        return size.width > 0 && size.height > 0
            && size.width <= 180 && size.height <= 60
            && center(of: element) != nil
    }

    private static func center(of element: AXUIElement) -> CGPoint? {
        guard let rawPosition = attribute(kAXPositionAttribute as CFString, of: element),
              let rawSize = attribute(kAXSizeAttribute as CFString, of: element),
              CFGetTypeID(rawPosition) == AXValueGetTypeID(),
              CFGetTypeID(rawSize) == AXValueGetTypeID() else { return nil }

        let positionValue = unsafeBitCast(rawPosition, to: AXValue.self)
        let sizeValue = unsafeBitCast(rawSize, to: AXValue.self)
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &position),
              AXValueGetValue(sizeValue, .cgSize, &size),
              size.width > 0,
              size.height > 0 else { return nil }
        return CGPoint(x: position.x + size.width / 2, y: position.y + size.height / 2)
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        attribute(kAXChildrenAttribute as CFString, of: element) as? [AXUIElement] ?? []
    }

    private static func role(of element: AXUIElement) -> String? {
        attribute(kAXRoleAttribute as CFString, of: element) as? String
    }

    private static func subrole(of element: AXUIElement) -> String? {
        attribute(kAXSubroleAttribute as CFString, of: element) as? String
    }

    private static func accessibleLabel(of element: AXUIElement) -> String {
        [
            kAXTitleAttribute,
            kAXDescriptionAttribute,
            kAXHelpAttribute,
            kAXValueAttribute,
            kAXIdentifierAttribute
        ]
        .compactMap { attribute($0 as CFString, of: element) as? String }
        .joined(separator: " ")
    }

    private static func attribute(_ name: CFString, of element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name, &value) == .success else { return nil }
        return value
    }
}

private extension String {
    func chunked(by size: Int) -> [String] {
        guard count > size else { return [self] }
        var result: [String] = []
        var index = startIndex
        while index < endIndex {
            let end = self.index(index, offsetBy: size, limitedBy: endIndex) ?? endIndex
            result.append(String(self[index..<end]))
            index = end
        }
        return result
    }
}
