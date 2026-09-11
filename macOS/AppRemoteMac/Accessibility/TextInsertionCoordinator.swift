import ApplicationServices
import AppKit
import RemoteCore

/// Écrit le texte à l'emplacement du curseur, avec repli contrôlé.
///
/// Trois méthodes, essayées dans l'ordre du plus propre au plus compatible :
/// écrire le texte sélectionné en AX, remplacer une plage de la valeur, puis
/// coller. Aucune application ne les supporte toutes, et aucune méthode ne
/// couvre toutes les applications — d'où la cascade plutôt qu'un choix unique.
@MainActor
final class TextInsertionCoordinator {

    private enum Attempt {
        case unsupported
        case noEffect
        case completed(InsertionResult)
    }

    /// Ce que chaque application a accepté au cours de la session.
    ///
    /// Utilisé pour aller plus vite la fois suivante, jamais pour sauter la
    /// vérification : une même application peut exposer un champ AX correct
    /// et, dans une autre fenêtre, un éditeur qui ne l'est pas.
    private var knownMethods: [String: InsertionMethod] = [:]
    func insert(_ text: String, into target: CapturedTarget) throws -> InsertionResult {
        guard !text.isEmpty else {
            throw RemoteErrorPayload(code: .internalFailure, detail: "texte vide")
        }
        // Vérifié avant toute écriture, tout presse-papiers, tout événement.
        guard !AccessibilityClient.isSecureInputEnabled else {
            throw RemoteErrorPayload(code: .secureField)
        }
        if let element = target.element, AccessibilityClient.isSecure(element) {
            throw RemoteErrorPayload(code: .secureField)
        }
        let preparedText = shouldPrependSpace(beforeTyping: text, in: target.element)
            ? " " + text
            : text
        guard preparedText.count <= ProtocolLimits.maxTextLength else {
            throw RemoteErrorPayload(code: .payloadTooLarge)
        }

        let exposesPlaceholderAsValue = target.element.map { element in
            InsertionVerificationPolicy.isPlaceholderExposedAsValue(
                value: AccessibilityClient.string(element, kAXValueAttribute),
                placeholder: AccessibilityClient.string(element, kAXPlaceholderValueAttribute)
            )
        } ?? false
        if InsertionMethodPolicy.requiresKeyboardEvents(
            bundleIdentifier: target.bundleIdentifier,
            applicationName: target.applicationName
        ) || exposesPlaceholderAsValue {
            // Les éditeurs OpenAI et Claude publient un arbre AX utile à la
            // détection du curseur, mais leurs écritures sont différées et non
            // transactionnelles. Les essayer avant CGEvent peut donc insérer
            // la même dictée deux fois ou matérialiser le texte d'aide.
            let result = try insertViaKeyboardEvents(preparedText, target: target)
            remember(.keyboardEvents, for: target)
            return result
        }

        if let element = target.element {
            collapseSelectionToEnd(in: element)
        }
        if target.element != nil {
            switch insertViaSelectedText(preparedText, target: target) {
            case .completed(let result):
                remember(.axSelectedText, for: target)
                return result
            case .noEffect:
                // AX a accepté la mutation. Certains éditeurs l'appliquent
                // après le retour de l'appel : tenter une seconde méthode ici
                // peut donc écrire deux fois. On rend un succès non vérifié et
                // on ne touche plus au champ.
                remember(.axSelectedText, for: target)
                return InsertionResult(
                    method: .axSelectedText,
                    verified: false,
                    pasteboardRestored: nil,
                    applicationName: target.applicationName
                )
            case .unsupported:
                break
            }

            switch insertViaValueRange(preparedText, target: target) {
            case .completed(let result):
                remember(.axRange, for: target)
                return result
            case .noEffect:
                remember(.axRange, for: target)
                return InsertionResult(
                    method: .axRange,
                    verified: false,
                    pasteboardRestored: nil,
                    applicationName: target.applicationName
                )
            case .unsupported:
                break
            }
        }

        if target.element == nil {
            // Certaines apps web natives (dont ChatGPT/Codex) masquent toute
            // leur hiérarchie AX, ou annoncent une écriture AX réussie sans
            // modifier leur contenu. Les événements Unicode n'utilisent pas
            // le presse-papiers et fonctionnent dans leur éditeur réel.
            let result = try insertViaKeyboardEvents(preparedText, target: target)
            remember(.keyboardEvents, for: target)
            return result
        }

        let result = try insertViaPaste(preparedText, target: target)
        remember(.paste, for: target)
        return result
    }

    /// Frappe directe au clavier, réservée à une action explicite de l'iPhone.
    ///
    /// C'est le seul chemin autorisé dans un champ sécurisé, et uniquement
    /// quand l'utilisateur a ouvert le clavier puis saisi ce texte. On ne peut
    /// pas relire un champ de mot de passe : le succès annoncé porte sur
    /// l'envoi des événements, pas sur le contenu.
    func typeManually(_ text: String, userInitiated: Bool) throws -> InsertionResult {
        guard userInitiated else { throw RemoteErrorPayload(code: .secureField) }
        guard AccessibilityClient.isTrusted else {
            throw RemoteErrorPayload(code: .permissionAccessibilityDenied)
        }

        guard CGEventFactory.type(text) else {
            throw RemoteErrorPayload(code: .internalFailure, detail: "événements clavier indisponibles")
        }
        return InsertionResult(
            method: .keyboardEvents,
            verified: false,
            pasteboardRestored: nil,
            applicationName: NSWorkspace.shared.frontmostApplication?.localizedName ?? "Application"
        )
    }

    // MARK: - Méthode 1 : texte sélectionné

    private func insertViaSelectedText(_ text: String, target: CapturedTarget) -> Attempt {
        guard let element = target.element else { return .unsupported }
        guard AccessibilityClient.isSettable(element, kAXSelectedTextAttribute) else { return .unsupported }

        let valueBefore = AccessibilityClient.string(element, kAXValueAttribute)
        let before = AccessibilityClient.range(element, kAXSelectedTextRangeAttribute)
        guard AccessibilityClient.setValue(element, kAXSelectedTextAttribute, text as CFString) else {
            return .unsupported
        }

        let valueAfter = AccessibilityClient.string(element, kAXValueAttribute)
        let after = AccessibilityClient.range(element, kAXSelectedTextRangeAttribute)

        // ChatGPT peut retourner kAXErrorSuccess tout en gardant exactement la
        // même valeur et la même sélection. C'est un non-effet explicite : on
        // doit continuer vers les événements clavier, pas annoncer une écriture.
        if InsertionVerificationPolicy.isConfirmedNoEffect(
            valueBefore: valueBefore,
            valueAfter: valueAfter,
            rangeBefore: before,
            rangeAfter: after
        ) {
            return .noEffect
        }

        let verified = InsertionVerificationPolicy.didApplySelectedText(
            insertedText: text,
            valueBefore: valueBefore,
            valueAfter: valueAfter,
            rangeBefore: before,
            rangeAfter: after
        )

        return .completed(InsertionResult(
            method: .axSelectedText,
            verified: verified,
            pasteboardRestored: nil,
            applicationName: target.applicationName
        ))
    }

    // MARK: - Méthode 2 : remplacement de plage

    private func insertViaValueRange(_ text: String, target: CapturedTarget) -> Attempt {
        guard let element = target.element else { return .unsupported }
        guard AccessibilityClient.isSettable(element, kAXValueAttribute),
              let current = AccessibilityClient.string(element, kAXValueAttribute),
              let selection = AccessibilityClient.range(element, kAXSelectedTextRangeAttribute) else {
            return .unsupported
        }
        guard !InsertionVerificationPolicy.isPlaceholderExposedAsValue(
            value: current,
            placeholder: AccessibilityClient.string(element, kAXPlaceholderValueAttribute)
        ) else {
            return .unsupported
        }

        let nsCurrent = current as NSString
        let location = min(max(0, selection.location), nsCurrent.length)
        let length = min(max(0, selection.length), nsCurrent.length - location)
        let updated = nsCurrent.replacingCharacters(in: NSRange(location: location, length: length), with: text)

        guard AccessibilityClient.setValue(element, kAXValueAttribute, updated as CFString) else {
            return .unsupported
        }

        let written = AccessibilityClient.string(element, kAXValueAttribute)
        if written == current, updated != current {
            return .noEffect
        }
        let verified = written == updated

        // Replace le curseur après le texte inséré : sans cela, la dictée
        // suivante repartirait du début du champ.
        var caret = CFRange(location: location + (text as NSString).length, length: 0)
        if let value = AXValueCreate(.cfRange, &caret) {
            AccessibilityClient.setValue(element, kAXSelectedTextRangeAttribute, value)
        }

        return .completed(InsertionResult(
            method: .axRange,
            verified: verified,
            pasteboardRestored: nil,
            applicationName: target.applicationName
        ))
    }

    // MARK: - Replis compatibles

    private func insertViaKeyboardEvents(_ text: String, target: CapturedTarget) throws -> InsertionResult {
        let valueBefore = target.element.flatMap {
            AccessibilityClient.string($0, kAXValueAttribute)
        }
        let rangeBefore = target.element.flatMap {
            AccessibilityClient.range($0, kAXSelectedTextRangeAttribute)
        }

        guard CGEventFactory.type(text) else {
            throw RemoteErrorPayload(code: .internalFailure, detail: "événements clavier indisponibles")
        }

        // CGEventPost est asynchrone. Une courte attente permet de vérifier le
        // champ réel sans annoncer prématurément une livraison réussie.
        Thread.sleep(forTimeInterval: 0.06)
        let valueAfter = target.element.flatMap {
            AccessibilityClient.string($0, kAXValueAttribute)
        }
        let rangeAfter = target.element.flatMap {
            AccessibilityClient.range($0, kAXSelectedTextRangeAttribute)
        }
        let verified = InsertionVerificationPolicy.didApplySelectedText(
            insertedText: text,
            valueBefore: valueBefore,
            valueAfter: valueAfter,
            rangeBefore: rangeBefore,
            rangeAfter: rangeAfter
        )

        return InsertionResult(
            method: .keyboardEvents,
            verified: verified,
            pasteboardRestored: nil,
            applicationName: target.applicationName
        )
    }

    private func insertViaPaste(_ text: String, target: CapturedTarget) throws -> InsertionResult {
        let transaction = PasteboardTransaction(writing: text)
        CGEventFactory.paste()

        // Laisse à l'application le temps de lire le presse-papiers. Les apps
        // Electron le font souvent de façon asynchrone ; restaurer trop tôt
        // colle l'ancien contenu à la place du texte dicté.
        Thread.sleep(forTimeInterval: 0.12)

        let restored = transaction.restore()
        return InsertionResult(
            method: .paste,
            verified: false,
            pasteboardRestored: restored,
            applicationName: target.applicationName
        )
    }

    private func remember(_ method: InsertionMethod, for target: CapturedTarget) {
        guard let bundle = target.bundleIdentifier else { return }
        knownMethods[bundle] = method
    }

    /// Une frappe Unicode remplacerait une sélection active. Le PTT étant
    /// append-only, on replie d'abord la sélection vers son extrémité droite.
    private func collapseSelectionToEnd(in element: AXUIElement) {
        guard let selection = AccessibilityClient.range(element, kAXSelectedTextRangeAttribute),
              selection.length > 0 else { return }
        var caret = CFRange(location: selection.location + selection.length, length: 0)
        if let value = AXValueCreate(.cfRange, &caret) {
            AccessibilityClient.setValue(element, kAXSelectedTextRangeAttribute, value)
        }
    }

    /// Détermine la frontière depuis la valeur AX et la position du curseur.
    /// Si une application ne publie pas son contenu (certains éditeurs web),
    /// on préfère ajouter la séparation : un éventuel espace initial est moins
    /// destructeur que deux mots fusionnés puis corrigés comme un seul mot.
    private func shouldPrependSpace(
        beforeTyping replacement: String,
        in providedElement: AXUIElement? = nil
    ) -> Bool {
        guard let first = replacement.first,
              first.isLetter || first.isNumber else {
            return false
        }
        guard let element = providedElement ?? AccessibilityClient.focusedElement(),
              let selection = AccessibilityClient.range(element, kAXSelectedTextRangeAttribute) else {
            return true
        }

        // Une sélection explicite signifie que l'utilisateur remplace le texte,
        // pas qu'il continue le mot placé avant elle.
        guard selection.length == 0 else { return false }
        guard selection.location > 0 else { return false }
        guard let current = AccessibilityClient.string(element, kAXValueAttribute) else {
            return true
        }
        if InsertionVerificationPolicy.isPlaceholderExposedAsValue(
            value: current,
            placeholder: AccessibilityClient.string(element, kAXPlaceholderValueAttribute)
        ) {
            return false
        }

        let value = current as NSString
        let location = min(selection.location, value.length)
        guard location > 0 else { return false }
        let composedRange = value.rangeOfComposedCharacterSequence(at: location - 1)
        guard let previous = value.substring(with: composedRange).last else { return false }
        if previous.isWhitespace { return false }

        // Ces signes ouvrent ou relient une expression : « l' » + « arbre »,
        // « dossier/ » + « fichier », etc. ne doivent pas recevoir d'espace.
        let noSpaceAfter: Set<Character> = ["(", "[", "{", "'", "’", "-", "–", "—", "/", "\\"]
        return !noSpaceAfter.contains(previous)
    }
}

/// Règles pures séparées de l'API C afin de tester les faux succès AX.
enum InsertionVerificationPolicy {
    static func isPlaceholderExposedAsValue(value: String?, placeholder: String?) -> Bool {
        guard let value, let placeholder,
              !value.isEmpty, !placeholder.isEmpty else {
            return false
        }
        return value == placeholder
    }

    static func isConfirmedNoEffect(
        valueBefore: String?,
        valueAfter: String?,
        rangeBefore: CFRange?,
        rangeAfter: CFRange?
    ) -> Bool {
        let valueDidNotChange = valueBefore != nil && valueBefore == valueAfter
        let rangeDidNotChange: Bool = {
            guard let rangeBefore, let rangeAfter else { return true }
            return rangeBefore.location == rangeAfter.location
                && rangeBefore.length == rangeAfter.length
        }()
        return valueDidNotChange && rangeDidNotChange
    }

    static func didApplySelectedText(
        insertedText: String,
        valueBefore: String?,
        valueAfter: String?,
        rangeBefore: CFRange?,
        rangeAfter: CFRange?
    ) -> Bool {
        if let valueBefore, let valueAfter, let rangeBefore {
            let source = valueBefore as NSString
            let location = min(max(0, rangeBefore.location), source.length)
            let length = min(max(0, rangeBefore.length), source.length - location)
            let expected = source.replacingCharacters(
                in: NSRange(location: location, length: length),
                with: insertedText
            )
            if valueAfter == expected { return true }
        }
        guard let rangeBefore, let rangeAfter else { return false }
        return rangeAfter.location > rangeBefore.location
    }
}

/// Exceptions de compatibilité fondées sur un comportement vérifié de l'app.
///
/// Cette liste reste volontairement exacte : on ne dégrade pas toutes les apps
/// Electron parce qu'un éditeur particulier implémente mal les écritures AX.
enum InsertionMethodPolicy {
    static func requiresKeyboardEvents(
        bundleIdentifier: String?,
        applicationName: String? = nil
    ) -> Bool {
        let keyboardEventBundles = [
            // Apple's Screen Sharing exposes the remote desktop as one opaque
            // AXSharedScreen element. AX/pasteboard insertion cannot see the
            // remote caret, while physical keyboard events are forwarded to it.
            "com.apple.screensharing",
            "com.openai.codex",
            "com.openai.chat",
            "com.openai.chatgpt",
            "com.anthropic.claudefordesktop"
        ]
        if let bundle = bundleIdentifier?.lowercased(),
           keyboardEventBundles.contains(where: { bundle == $0 || bundle.hasPrefix($0 + ".") }) {
            return true
        }

        guard let name = applicationName?.lowercased() else { return false }
        return name.contains("codex") || name.contains("chatgpt") || name == "claude"
    }
}
