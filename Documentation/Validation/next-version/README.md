# Validation de la prochaine version

Relevé du 11 septembre 2026. Recherche et implémentation sur la branche
`codex/duo-vps-windows`, [PR #6](https://github.com/ncleton/vibe-walkie/pull/6).

## Preuves obtenues

| Périmètre | Exécution | Résultat |
|---|---|---|
| Protocole Swift | RemoteCore, Xcode 26.2 | 78 tests réussis |
| Client iOS | Simulateur iOS 26.3, vues réelles | 34 tests réussis |
| Compagnon Mac | macOS, arm64 | 50 tests réussis et compilation réussie |
| Linux | Ubuntu 24.04, Xvfb, Openbox, GTK, xterm | 19 tests réussis, dont le lanceur VPS livré |
| Windows | Windows Server 2025, Python 3.12, bureau interactif | 18 tests réussis, dont les éditeurs réels WinForms et WPF |
| Client iPhone natif → Linux | Simulateur iOS 26.3, binaire signé localement, vrai compagnon Linux | Appairage Bonjour/TLS, insertion Unicode vérifiée et affichage du bureau dans les deux panneaux : test réussi |

Les [essais Windows et Linux du commit 65b4082](https://github.com/ncleton/vibe-walkie/actions/runs/34558471266)
utilisent les API des systèmes et un vrai flux TLS 1.3. Les tests ne remplacent
pas le bureau par un serveur simulé. Ils vérifient l’appairage Ed25519 avec
approbation locale, la saisie Unicode, les champs protégés, le pointeur, les
fenêtres et la capture JPEG. Linux vérifie aussi le changement de cible, les
rejeux, la révocation et l’absence de contrôle avant approbation.
L’essai Windows installe le compagnon par le script PowerShell livré puis lance
les tests depuis son environnement installé.

Le test du lanceur VPS crée une session distincte avec le script livré, connecte
un client authentifié, active xfce4-terminal, tape une commande, puis vérifie son
fichier de sortie. Ce test utilise un conteneur avec un vrai serveur X ; il ne
valide pas le réseau Tailscale d’un VPS déployé chez un hébergeur.

## Rendus et captures

Les cinq rendus iOS proviennent de la vue `RemoteHomeView`, avec son véritable
état déconnecté. Ce sont des tests de disposition aux tailles indiquées, sans
image distante inventée. Ils ne proviennent pas d’un simulateur Duo.

| Vue | Taille logique | Capture |
|---|---|---|
| Fermée, hauteur réduite | 420 × 620, classe compacte | [Voir](closed-short.png) |
| Fermée, paysage | 620 × 420, classe compacte | [Voir](closed-landscape.png) |
| Ouverte, paysage | 900 × 700, classe régulière | [Voir](open-landscape.png) |
| Ouverte, portrait | 700 × 900, classe régulière | [Voir](open-portrait.png) |
| Ouverte, portrait étroit | 620 × 880, classe régulière | [Voir](open-narrow-portrait.png) |
| Bureau Linux réel | Flux TLS reçu, JPEG 640 × 400 | [Voir](linux-live-screen.png) |
| Terminal du lanceur VPS | Flux TLS reçu, JPEG 640 × 400 | [Voir](vps-live-screen.png) |
| Windows, WinForms | Flux TLS reçu, éditeur réel | [Voir](windows-winforms-live.png) |
| Windows, WPF | Flux TLS reçu, éditeur réel | [Voir](windows-wpf-live.png) |
| iPhone connecté à Linux | Vue native de 900 × 700 points, image Linux réellement reçue | [Voir](native-iphone-linux-workspace.png) |

Les tests iOS vérifient également que la fermeture d’une ancienne vue écran ne
coupe pas le flux de sa remplaçante et que les raccourcis en attente d’un Mac
ne sont jamais envoyés à un hôte Windows/Linux. Une migration corrompue conserve
les données d’origine et continue de signaler l’erreur au prochain essai.

## Ce qui reste nécessaire avant une publication annoncée compatible Duo

- Compiler `scripts/build-duo.sh` avec le SDK iOS 27.1 ou supérieur, puis tester
  les régions de division réelles sur le simulateur Duo. Le SDK local est 26.2 ;
  la page Apple consultée liste encore Xcode 27 RC et iOS 27.
  La commande Apple `xcodebuild -downloadPlatform iOS -buildVersion 27.1`
  répond également le 11 septembre : `iOS 27.1 is not available for download.`
- Vérifier une ouverture/fermeture pendant une dictée réelle, les différentes
  poses et les régions d’occlusion de caméra. Les tests géométriques injectant
  des rectangles ne constituent pas cette validation matérielle.
- Contrôler la latence et la consommation sur iPhone avec chaque hôte par le
  réseau prévu. Les essais locaux ne prouvent pas une latence en mobilité.
- Tester Windows 11, le verrouillage, UAC et une déconnexion RDP sur les machines
  visées. Les essais actuels portent sur le bureau interactif de Server 2025.
- Vérifier le service systemd avec maintien de session et redémarrage sur le
  VPS de destination. Le lanceur réel est testé ; aucun VPS utilisateur n’a été
  déployé ou reconfiguré au cours de cette validation.

La dictée Linux nécessite un champ AT-SPI EditableText ; le terminal est pilotable
par le clavier manuel. Les sessions Wayland sont refusées avec une explication.
Ces limites sont aussi indiquées dans le [guide d’installation](../../../Companion/README.md).

## Reproduire

```bash
swift test --package-path Packages/RemoteCore
docker build -f Companion/tests/Dockerfile -t vibewalkie-companion-test .
docker run --rm --init vibewalkie-companion-test
```

Les workflows `CI` et `Windows and Linux companions` contiennent les commandes
des plateformes Apple et Windows. Le second conserve uniquement les captures
Windows de test comme artefacts, sans les identités TLS ni la base d’appairage.

### Essai du client iPhone natif

Le test `CompanionIntegrationTests` est un contrôle d’intégration distinct,
compilé avec `COMPANION_INTEGRATION`. Il exige un vrai compagnon Linux avec
`tests/gtk_editor.py` ouvert, son annonce Bonjour joignable et un simulateur
dédié sans appairages personnels. Il échoue si le QR ou l’hôte est absent.

Compiler pour le simulateur choisi avec `CODE_SIGNING_ALLOWED=YES`,
`CODE_SIGN_IDENTITY=-` et
`SWIFT_ACTIVE_COMPILATION_CONDITIONS=DEBUG COMPANION_INTEGRATION`. Installer le
binaire produit, puis copier la première ligne émise par `vibewalkie pair`
dans `Documents/companion-integration-qr.txt` du conteneur de cette application
(obtenu par `xcrun simctl get_app_container … com.nicolascleton.viberemote data`).
Lancer ensuite `xcodebuild test-without-building` avec le même projet, schéma,
simulateur et les mêmes options, en sélectionnant uniquement
`-only-testing:AppRemoteiOSTests/CompanionIntegrationTests`. Approuver la demande
sur l’hôte dans les 60 secondes avec la commande normale du compagnon.

Le test utilise `HostConnectionClient`, son Trousseau et son épinglage TLS,
insère une phrase dans le vrai champ GTK, attend le JPEG reçu et rend
`RemoteHomeView`. Son résultat conserve la capture comme pièce jointe. Le QR
et l’appairage temporaire sont retirés en fin de test. Le premier essai sans
signature a échoué avec l’erreur de Trousseau −34018 ; activer la signature
locale normale a permis le test complet, sans modifier l’authentification.
