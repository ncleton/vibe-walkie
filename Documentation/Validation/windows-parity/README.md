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
