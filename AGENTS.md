# Vibe Walkie : compagnons Mac et Windows

## Autorité des sources

Identifier la machine avec le skill `ordinateur-cible` avant de travailler.
Le dossier `/Volumes/Docker/Vibe Walkie` est un ancien checkout. Comparer
`origin/main` et la source de publication `/Volumes/Docker/App Remote` avant
tout changement. Préserver les modifications existantes ; utiliser un worktree
isolé pour l’intégration et ne jamais écraser un miroir Syncthing receive-only.

## Parité obligatoire

Toute amélioration ou correction du compagnon concerne **Mac et Windows dans
le même changement**, même si Nicolas ne nomme qu’une plateforme. Comparer les
interfaces, le protocole V4, les commandes, la configuration, la dictée, les
permissions, le retour écran, la posture, les assistants et les mises à jour.

Mettre à jour simultanément le code, les contrats, les tests et la documentation
des deux compagnons. Une API système différente est normale ; un résultat
utilisateur absent, une réussite non vérifiée ou une fonction factice ne l’est
pas. Ne pas annoncer la parité lorsqu’une ligne de
`Documentation/COMPANION_PARITY.md` n’est pas validée.

Les règles de posture de Windows sont les mêmes sources Swift que sur Mac.
Une modification de `PostureTypes.swift` ou `PostureAnalysisEngine.swift` doit
mettre à jour `Shared/PostureCore`, refaire les tests et vérifier les deux
acquisitions caméra. Le port Windows utilise WinUI, UI Automation, SendInput,
DXGI, les modèles caméra embarqués et les mises à jour MSIX signées.

## Vérifications et livraison

Exécuter `python3 scripts/verify-companion-parity.py`, les tests Swift, les tests
.NET et les tests natifs Windows affectés. La CI Windows doit se lancer aussi
sur les changements Mac et du protocole partagé. Le contrôle de contrat ne
remplace pas un essai réel de fonction.
Sur la machine de publication, ajouter `--mac-source "/Volumes/Docker/App Remote"`
au contrôle pour détecter aussi une évolution de la source Mac actuelle.

Une correction validée doit être publiée sur tous les canaux concernés et les
artefacts distants doivent être retéléchargés et vérifiés. Ne jamais générer un
certificat de confiance fictif, contourner la signature, annoncer une livraison
sur la seule compilation ou réduire silencieusement une fonctionnalité.
Une validation caméra, réseau ou signature bloquée doit être décrite précisément
avec la prochaine action requise. Une demande de préparation seule n’autorise
pas une publication éditoriale ni l’envoi de messages.
