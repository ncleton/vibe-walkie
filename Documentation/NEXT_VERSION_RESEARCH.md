# Vibe Walkie : iPhone Duo, VPS et Windows

## Orientation de la prochaine version

Vibe Walkie doit conserver une télécommande complète sur l’écran extérieur du
Duo et devenir un poste de travail en deux zones sur l’écran intérieur : image
distante dans une moitié, pavé tactile, dictée et commandes dans l’autre. Le même
client iPhone doit pouvoir sélectionner un Mac, un PC Windows ou un bureau Linux
hébergé sur VPS. Le changement d’ordinateur doit modifier le nom, les capacités
et les raccourcis disponibles, sans imposer une autre application mobile.

La voie retenue conserve le protocole V4 déjà présent dans le dépôt. Elle ajoute
un compagnon Windows/Linux avec des adaptateurs propres à chaque système et un
bureau virtuel explicite pour les VPS sans écran. Les choix ci-dessous distinguent
les faits publiés par les fournisseurs, les décisions de produit et les preuves
encore nécessaires avant une annonce de compatibilité.

## Ce qui est officiel pour l’iPhone Duo

Apple a annoncé l’iPhone Duo le 9 septembre 2026. La commercialisation annoncée
commence le 23 octobre, avec iOS 27.1. L’écran extérieur mesure 5,4 pouces et
l’intérieur 7,6 pouces. Les fiches officielles donnent respectivement 1398 × 2034
et 1878 × 2670 pixels. Ces dimensions matérielles ne constituent pas un contrat
de taille des vues SwiftUI : les points logiques, les marges, le clavier et le
multitâche déterminent la surface effective de l’application.[^1][^2]

La recommandation Apple est de prendre les décisions de disposition à partir
des classes de taille et de la géométrie disponible. L’écran extérieur est plus
court et large que les iPhone habituels. L’intérieur utilise un environnement
régulier, mais Split View peut encore réduire l’espace attribué à l’application.
Une distinction fondée uniquement sur « portrait/paysage », le nom commercial du
téléphone ou `UIScreen.main` serait donc fragile.[^3]

Le pli introduit une région de division et les caméras peuvent introduire des
régions d’occlusion. Les marges de sécurité peuvent être asymétriques. Les
conteneurs système adaptent une partie de leur disposition ; une télécommande
dessinée sur mesure doit tenir compte des régions réservées pour ses propres
commandes. La continuité entre les deux écrans doit préserver les fonctions et
la hiérarchie d’information.[^4]

Apple présente deux outils de disposition particulièrement pertinents : les
arrangements qui répartissent deux vues et les régions réservées accessibles
depuis la géométrie. Les exemples officiels montrent
`proxy.reservedRegions(kind: .division)` ainsi qu’`ArrangementView`. Le style
split change d’axe suivant l’espace et le pli. Il correspond directement au
couple « écran distant / surface de contrôle » envisagé ici.[^5]

La notification `onHingeChange` fournit aussi un état et un angle de charnière.
Apple la destine notamment aux interactions, et renvoie aux arrangements/régions
pour la disposition. Vibe Walkie n’a pas besoin de convertir un angle arbitraire
en une taille de panneau : la région effectivement indisponible est le signal
utile. Une future action liée au pli peut être ajoutée séparément, sans modifier
l’autorité sur la connexion ou l’envoi de la dictée.[^6]

## Expérience fermée : marche et télévision

La fonction principale reste l’appui pour parler, avec confirmation tactile et
retour d’état. Le pavé doit garder une surface utilisable ; les boutons ne doivent
pas se retrouver hors de l’écran quand sa hauteur diminue. Le choix de produit
est de réorganiser la zone des commandes sur les surfaces courtes, en conservant
les sept commandes configurées et l’accès à la palette globale.

Le mode compact n’active pas automatiquement le flux vidéo. Cela correspond au
besoin de contrôler sans garder les yeux sur le téléphone et évite de mobiliser
inutilement la capture et le réseau. Le bouton de vue écran reste accessible pour
vérifier le résultat. Aucun événement clavier ne doit être ajouté par le simple
changement de taille ou de pose du téléphone.

Les états déconnecté, enregistrement, transcription, envoi, réussite et erreur
doivent continuer d’être distingués. Une acceptation d’événements par le système
hôte n’est pas une preuve que l’application distante a effectivement reçu le
texte. Cette distinction existe déjà dans le contrôleur de dictée du dépôt et
doit rester vraie pour les nouveaux compagnons.

## Expérience ouverte : écran et commandes séparés

La disposition proposée montre automatiquement les deux panneaux lorsque
l’environnement est régulier et suffisamment large. En largeur dominante,
l’image est à gauche et les contrôles à droite. En hauteur dominante, l’image
occupe le haut et les contrôles le bas. Une région de pli active prend priorité
sur cette règle géométrique, afin de placer chaque panneau de son côté du pli.

Le contrôleur de dictée appartient à l’écran principal et ne doit pas être recréé
lors du changement de disposition. Les deux enfants du conteneur conservent leur
identité. Le flux distant possède un propriétaire explicite : la fermeture d’une
ancienne vue ne peut pas arrêter un flux que la nouvelle vue vient d’ouvrir. Le
passage au plein écran conserve le même hôte et la même dictée.

Les commandes et la barre de sélection de l’ordinateur appartiennent au panneau
de contrôle pour éviter qu’un bouton soit placé sur la charnière. L’image conserve
son rapport largeur/hauteur. Le pavé indépendant reste le moyen principal de
pointer, car le doigt ne masque alors pas la position visée sur l’image.

Le mode clavier nécessite un test spécifique : la réduction de la zone visible
ne doit ni recréer la session ni rendre inaccessible la fermeture du clavier.
Les changements de classe de taille, la rotation, le pli et le clavier sont des
entrées indépendantes. Les tests doivent combiner ces entrées, pas seulement
capturer un écran intérieur complètement ouvert.

Apple prévoit le déplacement de barres système vers le côté dans plusieurs
poses du Duo. Les symboles, regroupements de commandes et priorités de visibilité
sont mieux adaptés que de longues rangées de libellés. Vibe Walkie conserve ici
sa surface immersive personnalisée, tout en respectant les marges de sécurité ;
ses feuilles de réglages et de sélection peuvent bénéficier des comportements
système avec le SDK adapté.[^7]

## Ce qu’un VPS change réellement

Un VPS décrit une machine hébergée, pas un système graphique. Un VPS Linux peut
ne contenir qu’un serveur SSH ; dans ce cas il n’existe aucun écran à capturer.
Une compatibilité correspondant à l’expérience demandée nécessite donc soit
un bureau déjà actif, soit la création explicite d’une session de bureau virtuelle.

Xvfb fournit un serveur X11 sans matériel d’affichage ou périphérique physique.
Ses dimensions sont configurables et les programmes graphiques utilisent
réellement ce serveur. Il permet donc d’exécuter un gestionnaire de fenêtres, un
terminal, un éditeur et un navigateur dans une session hébergée. Le tampon vidéo
contient le résultat de ces applications ; il ne s’agit pas d’une image de terminal
reconstituée côté iPhone.[^8]

La décision est d’offrir un lancement de session avec Xvfb, un gestionnaire de
fenêtres et un terminal réel. Le serveur X n’écoute pas sur TCP. Seul le compagnon
expose son protocole privé. La durée de vie de la session est indépendante de la
connexion du téléphone ; fermer Vibe Walkie ne doit pas fermer le terminal ou
interrompre les processus que l’utilisateur y a démarrés.

Un utilisateur de VPS pourra ainsi ouvrir son éditeur, retrouver son terminal,
faire défiler un journal ou utiliser un outil graphique. L’installation reste
effectuée avec un compte utilisateur dédié. Les commandes ont les droits de ce
compte ; le fonctionnement ne nécessite pas que le compagnon soit root.

Le support natif Wayland est un chemin distinct. Le portail RemoteDesktop permet
de créer des sessions et de demander les périphériques d’entrée ; le partage
d’écran et les flux sont associés aux mécanismes de la plateforme. Traiter une
session Wayland comme une session X11 risquerait de donner un contrôle incomplet
ou de contourner l’expérience de consentement du bureau. Le compagnon X11 doit
donc refuser ce cas explicitement jusqu’à la disponibilité d’un adaptateur portail
complet.[^9]

## Capture, pointeur et texte sous Linux

L’extension XTEST fournit les événements de clavier et de pointeur synthétiques
au serveur X. Le compagnon transforme les commandes typées du protocole en ces
événements, avec des bornes de coordonnées et des phases explicites pour le
glisser-déposer. Une déconnexion doit relâcher le bouton tenu afin de ne pas
laisser le bureau dans un état de glissement permanent.[^10]

La dictée nécessite des garanties supplémentaires. AT-SPI permet d’interroger
le texte, le caret et l’interface EditableText. La méthode d’insertion documente
la différence entre position en caractères et longueur du texte en octets UTF-8.
Cette différence est importante pour les accents et les emoji. Le compagnon
capture une cible, vérifie à nouveau le champ et la sélection, insère le texte
puis lit le résultat pour confirmer l’opération.[^11][^12]

La saisie manuelle est un chemin séparé. AT-SPI décrit également une synthèse
de chaîne composée avec `ATSPI_KEY_STRING`, distincte de la simulation brute de
touches matérielles. Son fonctionnement effectif dépend de la pile de saisie et
doit être testé dans les applications retenues, en particulier le terminal. Une
réponse système positive ne peut pas être transformée artificiellement en une
dictée vérifiée.[^13]

## Windows : compagnon de session, capture et entrées

Le compagnon Windows doit tourner dans la session interactive de l’utilisateur.
Microsoft précise que les services ne peuvent pas interagir directement avec
l’utilisateur depuis Windows Vista et que les services s’exécutent en session 0.
Installer uniquement un service système donnerait un serveur réseau joignable,
mais pas l’accès au bureau demandé. Le lancement retenu est donc une application
utilisateur, avec installation dans son profil.[^14]

`SendInput` fournit les événements de souris et clavier. Il retourne le nombre
d’événements insérés, qu’il faut comparer au nombre demandé. Les règles UIPI
empêchent un processus d’injecter dans une application de niveau d’intégrité
supérieur ; les erreurs ne désignent pas toujours explicitement UIPI. Le produit
doit signaler le refus et inviter à revenir à une application normale, sans
élever silencieusement le compagnon.[^15]

La saisie Unicode s’appuie sur `KEYEVENTF_UNICODE`, dont Microsoft décrit le
transport sous forme de `VK_PACKET` puis de message caractère. Les paires de
substitution UTF-16 doivent être conservées pour les caractères hors BMP. Les
raccourcis utilisent des touches et modificateurs adaptés à Windows, avec Ctrl
pour copier/coller et Alt+Tab pour changer d’application.[^16]

UI Automation fournit l’élément qui possède le focus et une propriété indiquant
les champs de mot de passe. Le compagnon doit vérifier ces propriétés avant la
dictée et refuser les cibles protégées. L’identité d’élément, la fenêtre, le texte
et la sélection sont capturés au début puis contrôlés au moment de l’insertion.
Une comparaison du texte après l’envoi apporte la preuve utile pour la
confirmation sur l’iPhone.[^17][^18]

Les champs Edit Win32 et WinForms anciens disposent aussi d’un contrat natif :
`EM_GETSEL` donne les positions de sélection en unités UTF-16. Le compagnon le
prend en charge avec une lecture de texte bornée et un délai de réponse, sans
remplacer la vérification par une simple confirmation d’envoi. Les messages
système concernés sont transportés entre processus par Windows.[^21][^22]
Les appels UI Automation sont exécutés sur un thread MTA dédié, conformément à
la recommandation Microsoft pour éviter les problèmes de messages et de
réentrance.[^23]

La capture initiale s’appuie sur MSS et l’encodage JPEG déjà compris par le client
iPhone. MSS documente la capture de moniteurs et son utilisation avec Pillow.
Cela évite de modifier simultanément le transport et tous les décodeurs. Les
performances réelles, le changement de résolution et la session RDP doivent
néanmoins être mesurés sur Windows avant d’affirmer le support de ces scénarios.[^19]

## Réseau et appairage

Tailscale reste le transport distant privilégié. Le compagnon utilise le nom
MagicDNS et l’adresse privée du même hôte, avec le port V4. Les règles de grants
permettent d’autoriser une source vers une destination et des ports précis ;
elles s’additionnent, et une règle plus spécifique ne retire pas une autorisation
plus large. La documentation doit donc proposer une configuration à accès limité,
sans prétendre que l’application administre la politique du tailnet.[^20]

Le chiffrement Tailscale ne remplace pas l’authentification Vibe Walkie. Le QR
contient toujours l’empreinte du certificat et un secret temporaire. Le téléphone
prouve la possession de sa clé Ed25519 et l’opérateur approuve la demande sur
l’hôte. Sur un VPS, cette approbation peut être réalisée dans la connexion SSH
existante. Aucune ouverture publique de port ou page d’appairage n’est nécessaire.

Les réponses aux commandes déjà exécutées doivent rester disponibles après une
reconnexion brève. Le cache est attaché à l’identité du pair et au message ; un
même identifiant avec un contenu différent doit être refusé. Le jeton de dictée
reste à usage unique, y compris si l’insertion échoue. Ces règles empêchent qu’une
coupure provoque une double frappe ou qu’une phrase soit renvoyée vers un nouveau
champ.

## Contrat de validation avant publication

| Besoin | Preuve requise |
|---|---|
| Télécommande Duo fermée | Exécution sur le simulateur Duo, contrôles accessibles, gestes et dictée, tailles de texte agrandies |
| Deux moitiés ouvertes | Image réelle reçue, contrôles sur l’autre moitié, vérification des plis horizontal et vertical |
| Continuité ouverture/fermeture | Même session et même dictée pendant une séquence de plis ; aucun envoi supplémentaire |
| VPS sans écran | Session virtuelle démarrée sur Linux, terminal réel, contrôle par le protocole depuis un client authentifié |
| Windows | Installation puis test dans une vraie session Windows : écran, clavier, Unicode, pointeur, fenêtres et dictée |
| Refus sûrs | Mots de passe, UAC, session verrouillée, cible changée, révocation, gros messages et rejeux rejetés |
| Compatibilité Mac | Builds et tests du compagnon Mac et du client iPhone avec le protocole partagé |
| Installation exploitable | Instructions et scripts testés depuis un environnement propre, erreurs actionnables |

Une compilation réussie du code commun prouve la cohérence du code compilé, pas
le comportement des API Win32. Des rendus à des tailles proches du Duo permettent
de contrôler la disposition générale, mais ne prouvent pas la gestion native des
régions de pli. L’annonce finale doit s’appuyer sur ces preuves distinctes.

La machine de développement inspectée dispose de Xcode 26.2 et d’un runtime de
simulateur iOS 26.3. Le code de régions réservées est isolé derrière une compilation
Duo et un script exigeant le SDK iOS 27.1. Ce script échoue explicitement tant que
le SDK approprié n’est pas sélectionné. Cette limite doit rester visible dans le
suivi de validation ; elle ne justifie pas de présenter la compatibilité matérielle
comme déjà certifiée.

La page Apple des exigences Xcode consultée le 11 septembre liste Xcode 27 RC
avec le SDK iOS 27.[^24] La page dédiée au Duo annonce explicitement Xcode 27.1
bêta pour plus tard dans le mois : aucun lien de téléchargement n’est encore
proposé dans cette section. L’absence du SDK requis est donc une dépendance de
disponibilité externe, au-delà de la mise à niveau de la machine locale. Dès sa
publication, sélectionner ce Xcode avec `DEVELOPER_DIR`, lancer le script de
compilation Duo puis les scénarios natifs du tableau ci-dessus.[^25]

Les preuves effectivement obtenues et les points restant à vérifier sont
consignés dans [le dossier de validation](Validation/next-version/README.md).

## Sources

Sources consultées le 11 septembre 2026. Les versions de SDK et dates de
commercialisation se rapportent aux pages officielles consultées ; leur
disponibilité dans l’environnement de développement est vérifiée séparément.

[^1]: Apple, [Apple unveils iPhone Duo](https://www.apple.com/newsroom/2026/09/apple-unveils-iphone-duo/), 9 septembre 2026.
[^2]: Apple, [iPhone Duo — Technical Specifications](https://www.apple.com/iphone-duo/specs/), fiche officielle.
[^3]: Apple Developer, [Prepare your app for iPhone Duo](https://developer.apple.com/videos/play/tech-talks/111461/), Tech Talk, sections SDK, classes de taille et marges.
[^4]: Apple, [Designing for iPhone Duo](https://developer.apple.com/design/human-interface-guidelines/designing-for-iphone-duo), Human Interface Guidelines, 9 septembre 2026.
[^5]: Apple Developer, [Strike a pose with adaptive layouts on iPhone Duo](https://developer.apple.com/videos/play/tech-talks/111463/), Tech Talk, exemples de régions et arrangements.
[^6]: Apple Developer, [Leverage multiple displays and scenes on iPhone Duo](https://developer.apple.com/videos/play/tech-talks/111464/), sections charnière et choix des API.
[^7]: Apple Developer, [Raise the bar with iPhone Duo](https://developer.apple.com/videos/play/tech-talks/111462/), Tech Talk.
[^8]: X.Org, [Xvfb manual](https://xorg.freedesktop.org/archive/X11R7.0/doc/html/Xvfb.1.html), documentation de la fonction du serveur virtuel ; référence ancienne, installation actuelle testée séparément.
[^9]: XDG Desktop Portal, [Remote Desktop interface](https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.portal.RemoteDesktop.html), documentation de l’API.
[^10]: X.Org, [XTEST — XTestFakeKeyEvent](https://www.x.org/releases/X11R7.5/doc/man/man3/XTestFakeKeyEvent.3.html), manuel de l’extension.
[^11]: GNOME, [Atspi.EditableText.insert_text](https://gnome.pages.gitlab.gnome.org/at-spi2-core/libatspi/method.EditableText.insert_text.html), documentation AT-SPI 2.
[^12]: GNOME, [Atspi.Text.get_caret_offset](https://gnome.pages.gitlab.gnome.org/at-spi2-core/libatspi/method.Text.get_caret_offset.html), documentation AT-SPI 2.
[^13]: GNOME, [Atspi.generate_keyboard_event](https://gnome.pages.gitlab.gnome.org/at-spi2-core/libatspi/func.generate_keyboard_event.html), documentation AT-SPI 2.
[^14]: Microsoft Learn, [Interactive Services](https://learn.microsoft.com/en-us/windows/win32/services/interactive-services), mise à jour 7 janvier 2021.
[^15]: Microsoft Learn, [SendInput](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-sendinput), mise à jour 13 octobre 2021.
[^16]: Microsoft Learn, [KEYBDINPUT](https://learn.microsoft.com/en-us/windows/win32/api/winuser/ns-winuser-keybdinput), mise à jour 19 mai 2023.
[^17]: Microsoft Learn, [IUIAutomation.GetFocusedElement](https://learn.microsoft.com/en-us/windows/win32/api/uiautomationclient/nf-uiautomationclient-iuiautomation-getfocusedelement), référence Win32.
[^18]: Microsoft Learn, [IUIAutomationElement.CurrentIsPassword](https://learn.microsoft.com/en-us/windows/win32/api/uiautomationclient/nf-uiautomationclient-iuiautomationelement-get_currentispassword), mise à jour 5 octobre 2021.
[^19]: Python MSS, [Usage](https://python-mss.readthedocs.io/stable/usage.html), documentation stable consultée ; version utilisée fixée dans `Companion/pyproject.toml`.
[^20]: Tailscale, [Grants syntax](https://tailscale.com/docs/reference/syntax/grants), dernière validation indiquée 5 janvier 2026.
[^21]: Microsoft Learn, [EM_GETSEL](https://learn.microsoft.com/en-us/windows/win32/controls/em-getsel), sélection native des contrôles Edit.
[^22]: Microsoft Learn, [SendMessageTimeoutW](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-sendmessagetimeoutw), délais et transport des messages système.
[^23]: Microsoft Learn, [Understanding Threading Issues](https://learn.microsoft.com/en-us/windows/win32/winauto/uiauto-threading), utilisation du modèle COM MTA.
[^24]: Apple Developer, [SDKs and system requirements](https://developer.apple.com/xcode/system-requirements), versions disponibles consultées le 11 septembre 2026.
[^25]: Apple Developer, [Get ready for iPhone Duo](https://developer.apple.com/iphone-duo/), section « Xcode 27.1 beta », disponibilité annoncée « Coming later this month », consultée le 11 septembre 2026.
