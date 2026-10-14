# Validation de la mise à niveau Windows

État au 14 octobre 2026 : intégration native en cours dans la
[PR 10](https://github.com/ncleton/vibe-walkie/pull/10), version cible 1.0.76.
Il ne s’agit pas encore d’une version Windows publiée ou d’une parité complète
validée. Le tableau fonctionnel et les écarts se trouvent dans
[`COMPANION_PARITY.md`](../../COMPANION_PARITY.md).

## Référence et maintenance

Le manifeste `mac-reference.json` conserve les empreintes de la source Mac
actuelle consultée et celles du dépôt. `source-windows-sha256.json` conserve
l’état initial du compagnon Windows natif importé, sans ses fichiers de build.
Les sources de publication et les modifications préexistantes ont été préservées.

Les consignes `AGENTS.md` imposent désormais un changement conjoint Mac/Windows.
Une consigne ciblée dans `/Volumes/Docker/AGENTS.md` couvre également App Remote.
Le contrôle de parité surveille les fichiers Mac du dépôt, les routes V4 et
l’identité du moteur de posture Swift partagé. Sur la machine de publication,
`--mac-source "/Volumes/Docker/App Remote"` vérifie aussi la source Mac actuelle.
La CI native s’exécute sur tous les changements, y compris ceux du Mac seul.
Le workflow de livraison Mac attend aussi la livraison Windows signée réussie
de la même version et du même commit avant de publier le canal Mac.

## Vérifications réalisées

Sur le Mac mini de Nicolas : 14 tests de protocole, 11 tests du cœur Windows,
36 tests du moteur de posture partagé réussis. Les assemblages du cœur Windows
et des essais natifs ciblant Windows compilent sans erreur ni avertissement.

La CI Windows a compilé le véritable exécutable WinUI autonome et conservé un
artefact de validation avec
ses runtimes .NET/Windows App SDK, le worker caméra MediaPipe, ses modèles
vérifiés par SHA-256 et le moteur Swift. Le lancement de la fenêtre et la
présence des contrôles français ont été vérifiés par UI Automation ; la capture
DXGI a fourni un vrai JPEG. Le démarrage complet du serveur et les exécutables
caméra/Swift embarqués ont été exécutés avec succès, même sans leurs outils de
développement sur PATH. Les essais de saisie WinForms sous utilisateur standard,
de confirmation DNS-SD et de fermeture propre sont réussis.

Les tests utilisent un vrai champ WinForms sur le bureau interactif. Le runner
CI et son Explorateur étant élevés, la CI crée un véritable compte standard
temporaire et lance le champ cible par l’API Windows
[CreateProcessWithLogonW](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-createprocesswithlogonw).
L’accès au bureau est limité à ce compte puis les ACL sont restaurées ; le compte
est supprimé en fin de job. Le compagnon conserve son refus de piloter les
applications élevées. Cela reste un essai de CI : les permissions du compagnon
et des applications dans une vraie session utilisateur Windows 11 sont à valider.

## Preuve CI de la révision native

[Exécution réussie 38482816132](https://github.com/ncleton/vibe-walkie/actions/runs/38482816132),
commit `752c105ded9156d205b244cd0a8501257a7df08d` :

- Mac : 14 tests de protocole, 11 tests du cœur et 36 tests de posture réussis.
- Windows : les mêmes 61 tests et 2 essais natifs réels réussis, aucun ignoré.
  La saisie vérifie accents, caractère hors BMP, retour à la ligne et refus d’un
  champ modifié. DXGI fournit un vrai JPEG borné.
- La véritable fenêtre WinUI démarre avec ses contrôles français, son serveur
  et la publication DNS-SD confirmée. Le bouton Quitter arrête le processus avec
  un code de sortie nul, après le retrait de l’annonce réseau.
- Le worker caméra et le moteur Swift embarqués démarrent sans les outils de
  développement sur PATH. Une liste de caméras vide dans la CI ne valide pas une
  acquisition vidéo, une calibration ou les angles 3D.

[Artefact non signé de validation](https://github.com/ncleton/vibe-walkie/actions/runs/38482816132/artifacts/11858237950),
archive ZIP SHA-256 :
`a9609c2cdd6dcb9ba064853133a603c38dfba51eb956537950a8b75cfabaa059`.
Il n’est pas annoncé comme un installateur de production. Les modifications
ultérieures de ce rapport n’altèrent pas cette révision du code vérifié.

## Vérification étendue du 14 octobre

[Exécution réussie 38487969045](https://github.com/ncleton/vibe-walkie/actions/runs/38487969045),
révision `e7c9690a9a32b8f87ffbff42bb026f19ad740fac` : **67 tests Windows**
(14 protocole, 11 cœur, 6 natifs, 36 posture) et 61 tests partagés sur Mac,
aucun ignoré.

Les nouveaux essais natifs utilisent de véritables connexions TLS 1.3, le
certificat de transport CNG du compagnon et le registre DPAPI. Ils vérifient
l’approbation locale, les signatures invalides, les clients non appairés, la
révocation, la reconnexion et les reprises de commande sans double exécution,
le contrôleur unique, les mauvaises séquences/sessions et les trames trop grandes.
Ce client protocolaire de test ne remplace pas un iPhone ni un essai LAN/Tailscale.

La véritable fenêtre WinUI modifie une commande des sept zones, l’applique et
sa sauvegarde DPAPI est relue. Elle affiche les erreurs attendues en absence
d’installation MSIX et de sélection caméra, puis quitte normalement.
L’erreur d’identité de paquet est maintenant traduite en instruction explicite
pour installer le paquet signé ; une bascule de démarrage refusée est rétablie.

La validation par le SDK Windows a corrigé deux défauts qui étaient invisibles
à la compilation de l’exécutable : l’espace de noms du démarrage automatique
et l’ordre des permissions. Le MSIX non signé est créé et extrait par MakeAppx,
sans désactiver sa validation et sans installation, signature artificielle ou
publication. **1 994 fichiers** sont comparés après extraction. La préparation
réutilisée par la livraison signée impose la version de l’exécutable et retire
les fichiers de diagnostic propres à la CI.

L’audit de l’archive précédente a vérifié 2 116 empreintes de fichiers et analysé
547 binaires PE. Le bundle de posture contient désormais les **18 DLL réellement
requises** par son exécutable, dont les bibliothèques VC, et exclut 124 DLL
inutiles d’outils de développement. Son exécution est retestée sans les outils
sur PATH, avec lecture JSON et erreur explicite sur une entrée invalide.
Ces entrées de protocole ne constituent pas des observations de webcam.

[Artefact de cette révision](https://github.com/ncleton/vibe-walkie/actions/runs/38487969045/artifacts/11861235513),
ZIP SHA-256 retéléchargé et vérifié sur le Mac mini de Nicolas :
`c74404e7fd6dce5aa8671b6302a7233aa771c22a50014986ced703d21c303968`.
Il contient le bundle et le MSIX **non signés de validation** dans leurs dossiers
respectifs. Les 1 993 fichiers du bundle ont été vérifiés après retéléchargement,
ainsi que le hash du MSIX et les preuves UI. `artifact-audit-e7.json` conserve
ces résultats et le commit de fusion CI `6ea06f4b2b64b85b3119953c64e02594aaa8ab39`.
La preuve d’installation et de mise à jour de confiance reste absente.

## Blocages de livraison

- Aucun accès à une machine Windows 11 avec webcam n’est actuellement fourni
  pour les essais physiques de calibration, rendu, commandes, assistants et CRM.
- Les parcours iPhone, LAN/Tailscale, révocation, verrouillage, UAC et RDP doivent
  être testés sur cette machine ; la CI hébergée ne les remplace pas.
- Aucun certificat Windows de signature de confiance ni Publisher n’est
  configuré dans l’environnement GitHub `release`. Le paquet MSIX signé, son
  installation et sa vraie mise à jour doivent être vérifiés ensuite.

`verify-companion-parity.py --release` échoue explicitement tant que ces preuves
sont absentes. Aucun certificat artificiel et aucune preuve supposée ne sont
créés. Les bundles CI non signés portent `purpose: validation` ; ils ne sont
pas une distribution Windows publique. Le workflow de livraison signé est
préparé, mais n’a pas encore été exécuté avec un certificat réel.
