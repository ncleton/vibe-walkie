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

## Vérifications complémentaires en cours

L’[exécution 38492721494](https://github.com/ncleton/vibe-walkie/actions/runs/38492721494)
a réussi 68 tests Windows (14 protocole, 11 cœur, 7 natifs, 36 posture), sans
aucun ignoré. Elle ajoute la mesure du vrai pointeur avec de petits déplacements,
la répétition de touches et le relâchement du glisser à la fermeture TLS.
L’ensemble de cette exécution est cependant **en échec** : le parcours du
compagnon WinUI sous le compte standard temporaire ne présente pas sa fenêtre.
Le processus charge .NET et WinUI dans la même session que le vérificateur.
L’exécution 38495188104 précise que `Application.Start` renvoie
`COMException 0x8000FFFF`, avant le constructeur du compagnon. Le parcours réussi de l’interface cité plus haut
utilise le compte élevé du runner CI.

Un nouvel essai avec de vrais champs WPF et de mot de passe a également bloqué
la CI. Les appels du client de test sont désormais bornés et l’exécution est
arrêtée explicitement après son délai, sans export de mémoire. Les étapes fixes
du rendu et de la capture permettent de distinguer le lancement du champ,
sa découverte et la saisie. Aucun de ces deux parcours n’est annoncé comme
validé tant que leurs essais ne passent pas.

Le lancement précédent utilisait un autre compte dans la session du runner,
ce qui exerce « Exécuter en tant qu’un autre utilisateur ». Ce contexte diffère
d’une session normale ; Microsoft documente un problème apparenté dans
[Windows App SDK 2555](https://github.com/microsoft/WindowsAppSDK/issues/2555),
sans que cela prouve la cause exacte de notre exécutable autonome.
Le test actuel demande le véritable jeton UAC non élevé de l’Explorateur
connecté, vérifie l’identité de session et les droits puis lance le compagnon
avec ce jeton. Il échoue si ce jeton manque ; aucun jeton artificiel, changement
UAC ou repli administrateur n’est prévu. Son résultat reste à confirmer. Cela
ne remplace pas la validation sur un compte standard Windows 11 réel.

Les diagnostics du démarrage initial WinUI ont été étendus avant le constructeur
de l’application. Le manifeste corrige aussi l’identifiant de compatibilité
Windows et déclare la mise à l’échelle par écran, conformément au
[format documenté par Microsoft](https://learn.microsoft.com/en-us/windows/win32/sbscs/application-manifests).
Le rendu sur plusieurs écrans et leur mise à l’échelle reste à vérifier.
La CI continue à recueillir les autres diagnostics après un échec de l’essai
natif, mais un contrôle obligatoire refuse sa réussite et toute livraison si
ces essais échouent ou sont ignorés.

## Dernier résultat de CI

L’[exécution 38497057049](https://github.com/ncleton/vibe-walkie/actions/runs/38497057049),
révision `5339ac3a4ea440355d25538f346384b8ab927d87`, termine **en échec**.
Les 61 tests partagés Windows et 7 essais natifs réussissent, sans aucun ignoré.
La compilation WinUI, le lancement et le parcours complet de l’interface dans
le compte du runner réussissent aussi. Les workers embarqués sont exécutés.

Les deux essais supplémentaires WPF et WinUI ne peuvent pas démarrer leur
parcours sans privilèges administrateur : l’Explorateur du runner ne fournit
pas le jeton UAC non élevé requis. Le test échoue explicitement sur cette
condition, avant de lancer un processus élevé en substitution. Il faut fournir
une véritable session interactive Windows avec les droits ordinaires pour
achever ces validations ; une relance identique de cette CI ne lève pas ce
blocage. Le contrôle final de tests natifs échoue également, et le paquet signé
n’est ni construit ni publié.

L’[artefact de cette révision](https://github.com/ncleton/vibe-walkie/actions/runs/38497057049/artifacts/11863942643)
a été retéléchargé sur le Mac mini de Nicolas. Son SHA-256 est
`00070915459f90ed96a8fe79c9a7f4a7ce6a37d50d997c4ff396e04d2536d400`.
Les 1 993 empreintes de fichiers, les preuves du parcours WinUI et le manifeste
PE contenant les bonnes déclarations Windows et PerMonitorV2 sont vérifiés.
Le commit de fusion CI `cda836fa5cc745b86d5b22c8ce6a4bfa0513fe70` et la tête
ci-dessus ont le même arbre Git `7dd4eb0a72f203eef9e0aa3df76d5bc346c01b84`.
`artifact-audit-5339.json` conserve cet audit avec l’échec de CI et
`ordinaryUserValidated: false` ; aucune preuve manquante n’est supposée.

## Diagnostic final des droits de session

L’[exécution 38498670719](https://github.com/ncleton/vibe-walkie/actions/runs/38498670719),
révision `2b9510e0b35b7f794c2640c0f590fb5bbbfd12ab`, confirme 68 tests Windows
réussis et deux essais supplémentaires bloqués. Le helper vérifie maintenant
l’élévation réelle de l’Explorateur avant de demander un jeton lié ; si son jeton
est déjà non élevé, il l’utilise directement. Le jeton utilisé doit être
réellement non élevé et appartenir au compte du bureau connecté.

Le runner testé présente un Explorateur élevé et un type d’élévation 1.
La demande de son jeton lié échoue avec **Win32 1312** (aucune session de
connexion correspondante). Ce diagnostic ne suppose pas une cause dans le
compagnon et ne prouve pas le comportement d’une session Windows 11 ordinaire.
La CI complète reste en échec ; les essais WPF et WinUI sans privilèges
administrateur ne sont pas considérés comme validés.

La source du compagnon n’a pas changé depuis l’artefact audité `5339` ; cette
révision corrige uniquement le contexte et le diagnostic du test. Aucun paquet
signé, aucune installation de confiance et aucun parcours webcam/iPhone ne
sont ajoutés aux preuves. Il faut une véritable session Windows 11 avec webcam,
un iPhone pour les parcours réseau et le certificat Windows de publication
pour poursuivre la validation complète.

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
