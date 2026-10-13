# Compagnon Windows natif

Compagnon WinUI du même produit que l’application Mac. Ses commandes utilisent
les contrats V4 de l’iPhone. Voir `../Documentation/COMPANION_PARITY.md` pour
les validations et écarts ouverts : ce chantier n’est pas encore une livraison.

Windows 11 24H2 x64, .NET 10 SDK et Windows App SDK 2.4 sont requis pour compiler.
La distribution doit embarquer ses runtimes ; Python et Swift ne doivent pas
être installés par l’utilisateur final.

```powershell
dotnet test Windows/VibeWalkie.Protocol.Tests -c Release
dotnet test Windows/VibeWalkie.WindowsCore.Tests -c Release
dotnet build Windows/VibeWalkie.WindowsCore -c Release
swift test --package-path Shared/PostureCore -c release
./Windows/scripts/build-validation.ps1
```

Le builder embarque le worker caméra MediaPipe et les modèles upstream exacts
vérifiés par SHA-256, ainsi que le même moteur de posture Swift que Mac. La
caméra est désactivée tant que l’utilisateur ne démarre pas le coach. Les
images et squelettes restent en mémoire dans les processus locaux ; seules
les bornes des sessions de marche sont persistées.

Le port source se compile sur Mac avec `EnableWindowsTargeting`. Les essais
Win32, DXGI, WinUI et caméra exigent Windows ; une compilation Mac ne les valide
pas. La CI conserve un artefact explicitement non signé de validation.

Avant distribution, signer le MSIX avec un certificat de confiance dont le
subject correspond au Publisher du manifeste ; vérifier sa signature puis
publier le paquet et son App Installer en HTTPS. Les mises à jour manuelles et
automatiques utilisent l’association App Installer réellement installée. Un
canal absent produit une erreur ; aucune URL de livraison n’est inventée.
