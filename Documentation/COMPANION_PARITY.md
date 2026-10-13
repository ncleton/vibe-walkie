# Parité Mac et Windows

Demande de Nicolas du 13 octobre 2026 : chaque amélioration du compagnon doit
être faite et validée simultanément sur Mac et Windows.

La référence fonctionnelle est le compagnon Mac 1.0.76 et ses sources actuelles
sur le Mac mini de Nicolas, dans `/Volumes/Docker/App Remote`. Le checkout
historique et GitHub main sont antérieurs à cette source. Le manifeste
`Validation/windows-parity/mac-reference.json` conserve les empreintes exactes
consultées, sans secrets. Le compagnon WinUI existant de cette source a été
préservé puis intégré dans le worktree `windows-mac-parity`.

## Contrats et fonctions

| Fonction | Port Windows | Validation nécessaire pour une livraison |
|---|---|---|
| Appairage QR, six chiffres, approbation et révocation | WinUI, Ed25519, TLS 1.3, identité protégée par utilisateur | Session Windows et iPhone réels |
| Dictée, sélection, Unicode et consommation du jeton | UI Automation et contrat Edit Win32 ; contenu réellement relu | WinForms/WPF, champs réels des applications utilisées |
| Clavier, répétition, menus, souris, zoom, glisser et pointeur fin | SendInput, SetCursorPos, intégration des fractions, budget gestes 180/s | Mesure interactive ; libération à la déconnexion |
| Sept commandes, palette Global et raccourcis | Éditeur WinUI, configuration DPAPI, diffusion aux clients | Deux appareils et ordre de palette |
| Retour écran | DXGI, JPEG, limite tenant compte du double base64 ; arrêt explicite des erreurs | GPU Windows, bureau statique et changement d’affichage |
| Agent CRM | Lecture native des métadonnées Chromium, origine HTTPS et défi lié au marqueur | Chrome/Edge/Brave avec le vrai CRM |
| Contrôle du microphone d’assistant | Contrôles visibles de l’application au premier plan | Versions Windows de Codex/ChatGPT/Claude |
| Actions vocales | Jev TypeSafe/OpenRouter, choix bornés aux éléments observés, confirmation et résultat vérifié | Compte réel, parcours multi-étapes ; sous-actions à compléter ci-dessous |
| Posture et marche | Mêmes types et moteur Swift que Mac ; MediaPipe local embarqué côté caméra Windows | Webcam réelle, calibration, orientation 3D et cadence |
| Historique marche et résumé Santé | Sessions durables ; mêmes agrégats et contraintes V4 | Consentement Santé et iPhone réel |
| Mises à jour et démarrage | API MSIX/App Installer et StartupTask | Paquet de confiance signé, installation puis vraie mise à jour |

Le H.264 du chantier `App Remote-latency` n’est pas encore livré sur le Mac.
L’alignement de ce chantier doit porter sur les deux compagnons avant sa
publication. Ne pas annoncer un codec que le backend ne peut pas produire.

## Écarts restant ouverts

La présence d’une route protocolaire et une compilation ne suffisent pas à
annoncer l’identité de comportement. Les sous-actions de téléversement, raccourcis dictés et coordonnées explicites
sont implémentées mais attendent les parcours réels Windows. Le contrôle précis
des onglets doit être comparé avec la lecture native et le pont Chrome du Mac. L’interface implémente l’ordre et les icônes des commandes, la bulle de posture
avec référence calibrée et les préférences persistantes ; leur rendu et leur
parcours doivent être vérifiés sur Windows. Les assertions de résultat doivent porter sur les vrais contrôles
Windows, sans simulation ni succès supposé.

Le moteur de posture Swift est partagé par identité de source, mais les
observations Vision et MediaPipe ne sont pas interchangeables sans validation
caméra : le corps 3D et les angles de tête nécessitent une comparaison réelle.

## Maintenance et contrôles

Lire `AGENTS.md`. Le workflow `Native Mac and Windows parity` s’exécute sur
chaque PR et chaque changement de main, y compris un changement Mac seul.
`verify-companion-parity.py` bloque toute évolution des contrats Mac sans
révision du manifeste et des adaptations Windows. Il vérifie les routes Windows
et l’absence de filtre de chemins dans le workflow. Les tests fonctionnels
et le contrôle de livraison restent distincts.
Le workflow de publication Mac attend le succès de la livraison Windows signée
de la même version et du même commit avant de publier son canal. Le script
`require-windows-release.py` vérifie également la preuve publique Windows.

`python3 scripts/verify-companion-parity.py --release` refuse une livraison tant
que les preuves Windows 11, caméra, interface, LAN, Tailscale, verrouillage/UAC/RDP,
signature MSIX de confiance et App Installer public sont absentes. Les sources
peuvent être compilées pour validation ; ces artefacts non signés ne sont pas
une version distribuable. Aucun certificat de confiance artificiel ne doit être
créé pour passer ce contrôle.
