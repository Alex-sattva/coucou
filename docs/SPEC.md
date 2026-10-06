# Notch Buddy — spécification

Toutes les mesures sont en points macOS. Les valeurs viennent de `reference/notch-buddy.html` (constantes `NW`, `NH`, `EW`, `VIEWS`, `STATES`, `EMOTES`, `PISTES`, `AGENTS`, classe `Bot`). En cas de doute, relire le code du prototype.

---

## 1. Fenêtre et notch

- Une `NSPanel` sans bordure : `styleMask [.borderless, .nonactivatingPanel]`, fond transparent, sans ombre, niveau au-dessus de la barre de menus (`.mainMenu + 3` ou équivalent qui passe au-dessus de la barre et des apps plein écran), `collectionBehavior [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]`.
- Taille fixe 720 × 320, ancrée en haut au centre de l'écran qui a un notch. L'island est dessinée dedans, collée au bord haut.
- **Clics traversants** : la zone transparente ne doit jamais bloquer les clics. Toggle `ignoresMouseEvents` à 60 Hz selon que `NSEvent.mouseLocation` est dans la forme de l'island (plus 6 pt de marge) ou pas.
- La panel peut devenir key uniquement quand un champ texte de l'island a le focus (prompt, mail). Sinon elle ne vole jamais le focus.
- Détection du notch : `NSScreen.safeAreaInsets.top` > 0 et `auxiliaryTopLeftArea` / `auxiliaryTopRightArea`. Largeur du notch `wN` = largeur écran − les deux zones auxiliaires ; hauteur `hN` = `safeAreaInsets.top`. Le prototype utilise `wN = 184`, `hN = 32` : dans l'app, prendre les vraies valeurs.
- Pas d'écran avec notch (Mac de bureau, écran externe ou capot fermé) : afficher sur l'écran principal une barre noire de 80 pt au repos (`hidden`), avec Mochi visible au centre et son animation en pause ; 240 pt en `compact`, en haut au centre. Hauteur plafonnée à 24 pt et à celle de la barre de menus ; personnage et pastilles adaptés à cette hauteur. Le salut se replie vers les dimensions réelles de la barre compacte. La zone de survol au repos ne déborde pas sous la barre. Les vues ouvertes gardent leur largeur de 640 pt.
- Suivi de la souris : polling de `NSEvent.mouseLocation` à chaque frame. Aucune permission nécessaire.

### Forme de l'island
- Rectangle noir `#000`, coins hauts carrés (il se fond dans le bord de l'écran), coins bas arrondis : 14 pt en hidden/peek/compact, 30 pt en expanded.
- Deux « oreilles » concaves de 14 pt aux coins hauts, à l'extérieur, pour que la forme coule dans le bord de l'écran (voir `#island::before/::after` du prototype).

## 2. Modes de l'island

| Mode | Largeur | Hauteur | Bonhomme | Agents secondaires |
|---|---|---|---|---|
| `hidden` | wN | hN | invisible | invisibles |
| `peek` | wN + 64 | hN | Ø 18, centre x = 19 | invisibles |
| `compact` | wN + 104 | hN | Ø 20, centre x = 27 | grille 2×2 dans l'oreille droite |
| `expanded` | 640 | selon la vue (§5) | selon la vue | selon la vue |

(Ø = diamètre du corps. Le canvas du personnage fait Ø / 0,6 de côté : le corps occupe 60 % du canvas, le reste sert aux particules, mains et badge.)

Grille compact : pastilles Ø 9,5 autour du point (largeur − 27, hN/2), écart ±6. 1 agent : centré. 2 : côte à côte. 3 : deux en haut, un en bas. 4 : carré.

## 3. Règles de comportement (validées par Louis)

1. **Rien ne tourne** → `hidden`. Totalement invisible.
2. **Souris sur le notch** alors que `hidden` → `peek` immédiatement, le bonhomme sort en faisant coucou (mains + son `peek` + son `greet`). Si la souris reste 650 ms → `expanded` (vue `overview`, ou `empty` s'il n'y a aucune tâche). Si elle part pendant le peek → retour `hidden` après 600 ms.
3. **Des tâches tournent et Louis est actif** → `compact` : très fin, le bonhomme visible, il suit la souris des yeux partout sur l'écran.
4. **Survol en compact** → `expanded` après 200 ms. Clic sur le bonhomme en compact → `expanded` tout de suite.
5. **Fermeture auto** : une fois ouverte, l'island se replie après **60 s sans activité** (mouvement de souris sur l'island, clic, frappe). Quitter l'island ne la ferme pas. Pendant les 10 dernières secondes, un trait de 2 pt en bas au centre (160 pt → 0, blanc 35 %) montre le compte à rebours. `Échap` ferme.
6. **Louis absent** (aucun mouvement de souris depuis 3 min, réglable) → `hidden`, même avec des tâches. Au premier mouvement → retour `compact` si des tâches tournent.
7. **Alertes** (permission, question, erreur) : l'island s'ouvre seule sur la vue de l'alerte, **même si Louis est absent**, et reste ouverte (pas de fermeture auto) jusqu'à sa réponse. Pour une **permission**, la vue `approval` rend le harness : la décision se prend dans le riser, en ligne, sans changer la taille de l'île.
8. **Terminé** : l'island s'ouvre sur la vue `finished` pendant 5,2 s, puis retire la tâche et se replie.
9. Plusieurs alertes en même temps : file d'attente, une à la fois, l'ordre d'arrivée.
10. **Focus** : le gros bonhomme représente la tâche en focus (la dernière alerte, sinon la première qui travaille). Les autres tâches sont les mini-bonhommes. Cliquer un mini-bonhomme le met en focus.

## 4. Animations de l'island

- Ouverture / agrandissement : 520 ms, ressort avec léger dépassement, équivalent `cubic-bezier(.32,1.22,.42,1)`. En SwiftUI, partir de `.spring(response: 0.5, dampingFraction: 0.72)` et ajuster à l'œil contre le prototype.
- Fermeture / rétrécissement : 340 ms, `cubic-bezier(.45,0,.2,1)`, sans dépassement.
- Largeur, hauteur, rayon, position et taille du bonhomme, position et taille des mini-bonhommes animent **ensemble** (effet « élément partagé » : les mini-bonhommes passent de la grille aux pastilles puis à la colonne sans disparaître).
- Contenu des vues : sortie 160 ms (opacité 0, flou 8, échelle 0,97) ; entrée 300 ms avec 160 ms de retard (après que le conteneur a commencé à grandir). L'en-tête apparaît avec 300 ms de retard.
- Mini-bonhommes : décalage de 35 ms par index.
- Libellés des pastilles : apparaissent 220 ms après le début du mouvement.
- Au passage en `expanded`, le bonhomme cligne des yeux.
- Sons : `open` à l'ouverture, `close` à la fermeture.

## 5. Vues (mode expanded, largeur 640)

Structure commune : en-tête de 34 pt (onglets à gauche : Vue d'ensemble, Demander, Déposer ; à droite : « N en cours » + bouton son). Contenu inséré de 36 en haut, 10 à gauche, droite, bas. Cartes : rayon 20, fond `#141518`, bord blanc 3,5 %. Dans les vues autres que `overview`, les mini-bonhommes passent en **colonne** à droite (Ø 16, x = largeur − 31, y = 50 + i × 24) et la carte laisse 42 pt à droite. Exception : sur les surfaces du harness (`overview`, `approval`) le `BotPlacement` partagé est masqué, car `HarnessVoiceView` dessine son propre Mochi dans sa carte agent — sinon le bonhomme de 58 pt se superposerait au Mochi de 26 pt.

Voile de couleur des cartes : dégradé radial depuis le bas (120 % × 90 %, centre 50 % / 130 %), couleur de l'état :
rouge `rgba(244,80,94,.55)`, vert `rgba(52,211,153,.5)`, rose `rgba(244,114,182,.55)`, ambre `rgba(245,165,36,.42)`, cyan `rgba(34,211,238,.38)`, indigo `rgba(99,102,241,.5)`, neutre `rgba(255,255,255,.08)`.

| Vue | Hauteur | Bonhomme (x, Ø) | Contenu | Capture |
|---|---|---|---|---|
| `overview` | 160 | 68, 58 | harness vocal : carte gauche 296 (grand Mochi + ligne agent + défilé/riser + barre vocale) ; carte droite : 2×2 pastilles-espaces de travail + chip Main | 03 |
| `empty` | 150 | 70, 62 | « Rien ne tourne pour l'instant. » + bouton « Demander à Claude » | 16 |
| `approval` | 160 | 62, 56 | harness vocal (même surface que le home) : la permission est répondue **en ligne**, dans le riser de la carte gauche, sans que la carte change de taille | 04 |
| `question` | 196 | 62, 56 | agent + question (1/N) + options en boutons (single-select ou multi-select) + « Reply in terminal » ; bouton Send/Next pour multi-select ou multi-questions ; « Other… » → saisie libre | 05 |
| `error` | 190 | 62, 58 | agent + outil, titre, détail en rouge `#FF8D97`, Relancer, Ouvrir dans n8n | 06 |
| `finished` | 170 | 62, 58 | agent + résumé, Voir le terminal, OK | 07 |
| `confused` | 160 | 76, 66 | « Trop de claques d'un coup. » | 08 |
| `upload` | 176 | 140, 62 | zone pointillée, « Dépose tes fichiers ici », étiquettes | 09 |
| `uploading` | 150 | sur la barre, Ø 28 | « Envoi de fichier » + %, barre verte, le bonhomme est le curseur de la barre | 10 |
| `choose` | 170 | 60, 52 | « fichier est prêt. », Poser une question dessus, Envoyer par mail | 11 |
| `mail` | 210 | 56, 46 | champs À, Objet (+ Message optionnel), Envoyer, Annuler | 12 |
| `prompt` | 156 | 52, 44 | pastille de contexte + puce de modèle (clic → sélecteur fournisseur/modèle) + champ + micro + envoyer | 13 |
| `searching` | 156 | 52, 44 | contexte + texte scintillant « Claude lit la page et cherche sur le web… » | 14 |
| `result` | 262 (s'adapte au contenu, max 320) | 52, 44 | titre, 3 lignes de résultat, boutons | 15 |
| `note` | 136 | 60, 50 | message court (mail envoyé, copié, j'ouvre n8n…), se ferme seul après 2 s | — |

Centre vertical du bonhomme : 36 + (hauteur − 46) / 2, sauf `result` (y = 86).

### Voice harness (overview)
`overview` est le **home** de l'île : `HarnessVoiceView` (fichier `HarnessVoiceView.swift`), qui remplace l'ancienne `OverviewView` supprimée. Maquette de référence : `design/prototype/harness-main-voice.html`. La géométrie de fenêtre ne change pas : largeur 640, hauteur 160, contenu de 98 pt. Toutes les courbes et durées viennent de `HarnessMotion`, toutes les mesures de `HarnessMetrics` (même fichier) — aucun ressort ad hoc.

**Carte gauche (296 pt).** Vignette du harness au-dessus, fond `#141518`, rayon 20, voile radial dans la couleur de l'espace de travail au focus (centre 22 % / 128 %, opacité 22 %, atténuation 62 %). De haut en bas :
1. **Ligne agent** (26 pt) — grand Mochi (`HarnessMochiView`, Ø 26, colonne de 30 pt) puis, sur deux lignes : pastille de couleur 7 pt + nom + outil courant ; compteur d'étapes `n/N` (monospace, `#6B7079`) + bouton d'expansion (seulement pour une pastille d'intégration, voir **Cartes de détail**) + bouton horloge (popup Threads) + bouton `+` (nouvelle session, pointillé seulement si `canStartNewSession`). L'horloge et le `+` vivent sur la carte agent, pas dans l'en-tête partagé.
2. **Créneau unique** (`.frame(maxHeight: .infinity)`, découpé) — trois occupants qui s'excluent, dans cet ordre : **riser** (permission ou question, 26 pt) ; sinon **résumé de fin** ; sinon **défilé de tâches**. À 98 pt, un riser et un défilé ne peuvent pas cohabiter : le riser *remplace* le défilé, exactement comme `.slot.done` / `.riser-on` dans la maquette.
3. **Barre vocale** (`VoiceBarView`) — voir plus bas.

**Carte droite.** En-tête « WORKSPACES » 9 pt + chip **Main** à droite ; grille 2×2 de pastilles-espace de travail ; pied de carte (point bleu + « N agents running · tap a Mochi to make it the main » ou « all agents idle · … »).

**Motion.** `HarnessMochiView` pilote `BotEngine` directement (`bodyColor` = couleur de l'espace, `setState`) et impose ses postures **après** `engine.update(dt:)` en ajoutant à `engine.locks` **les seules clés que la posture écrit** (`sx`, `sy`, `oy`, `ox`, `tilt` au total) — c'est ce qui prime à la fois sur les tweens et sur le lissage, et une clé qu'une posture n'écrit pas reste déverrouillée : elle revient au neutre au lieu de geler sur la valeur de l'état précédent. Postures : `listening` respire 1,6 s, `speaking` mâchouille 0,5 s, `working`/`thinking` penche et oscille, `approval` rebondit, `question` penche à 0,17, `error` tremble en x, `sleeping` respire. Un `hopToken` incrémenté joue le saut (squash-stretch + anneau). Anneau : giratoire en couleur d'espace pendant `working`, « ping » pendant `listening`.

**Vol de pastille (`pillFlight`).** Un point quitte la pastille touchée et rejoint le grand Mochi, puis éclate en 14 éclats sur `pillBurstRadius`. Les positions viennent d'un `AnchorPreferenceKey` (`HarnessAnchorKey`, clé Mochi = `"\u{0}mochi"`), résolu par un `GeometryReader` en superposition. La base de temps est `Date.timeIntervalSinceReferenceDate` (celle de `TimelineView`), **pas** `CACurrentMediaTime()`.

**Coût CPU.** Toutes les vues animées du harness prennent un `isPaused` alimenté par `isLive` (`state.mode == .expanded && state.view == view` : chaque instance compare sa **propre** vue, car `IslandRootView` garde un corps vivant par cas et `overview` comme `approval` montent donc chacun un harness — la copie hors écran doit rester immobile et ne rien dessiner) : masquée ou remplacée par une autre vue, l'île reste à 0 % de CPU (le Mochi, le défilé, les anneaux de pastille, la barre vocale, le vol de pastille et le popup compris).

**Cartes de détail.** Trois cartes livrées, présentées **sans modification**, s'ouvrent par-dessus le harness. Le **diff** (⌘E, ou un pas cliqué depuis la carte d'intégration) et la **jauge de contexte** couvrent toute la surface : à ~100 pt de haut elles ne tiennent pas dans le créneau (~30 pt), et une carte de diff a besoin de largeur. Elles reprennent telles quelles `DiffCardView` / `ClaudePlanCardView`, par-dessus un `CardBackground`. La **carte d'intégration** (`IntegrationCardView`, ~480 lignes, la seule à savoir ouvrir VS Code) s'ouvre, elle, **dans la carte gauche** — sa place d'origine : le roster reste donc vivant, et toucher un autre espace de travail (ou Échap) est la sortie naturelle ; elle n'a pas de bouton de fermeture propre, et elle reçoit sa propre plaque (`CardBackground(wash: nil)`) car `IntegrationCardView` n'en peint aucune : posée seule, elle laissait lire au travers la ligne agent, le défilé et le champ restés vivants dessous. Le focus du harness est **reflété dans `AppState`** (`VoiceHarnessModel.focus` appelle `setFocus`) : la pastille, le Mochi livré et les raccourcis clavier de l'app (⌘←/⌘→, ⌘1–9, `cyclePill`) désignent donc toujours le même espace de travail, et changer de focus — par n'importe quelle route — referme la carte ouverte. Une permission en attente passe avant les trois : le riser est la seule façon de répondre.

**Reprises de l'ancien home.** Supprimer `OverviewView` emportait des comportements non visuels ; ils sont repris à l'identique. La carte d'intégration reste atteignable (bouton d'expansion sur la ligne agent), et focaliser la pastille GitHub — ou déplier l'île avec elle au focus — appelle toujours `GithubPoller.shared.refreshIfStale()`. Le Mochi livré de l'île (`BotPlacement`, 58 pt) est **masqué** sur une surface de harness, comme il l'était sous Upload et Greeting ; `isBotHit` renvoie donc faux sur ces surfaces, sinon son cercle de frappe invisible (r ≈ 48 pt, centré (68, 101)) avalait les clics sur la carte gauche — Mochi, ligne agent, texte du riser, moitié gauche du champ — et trois clics y faisaient basculer l'île en `.confused` pendant 3,3 s. Le **défilé du home est en lecture seule** : avant 0.1.8, cliquer un pas ouvrait la carte de diff ; ⌘E l'ouvre toujours. Enfin le `MusicPill` du home (lecture/pause, `#if !APPSTORE`) **n'est pas repris** : la maquette ne prévoit pas de pilule musicale et le roster 2×2 le remplace. La `MusicCardView` (réglages d'automatisation Apple Music) reste atteignable depuis la carte d'intégration de `integration_music`, mais lancer/mettre en pause la musique depuis l'île ne l'est plus — à trancher.

### Barre vocale (voice bar)
`VoiceBarView` (`model : VoiceHarnessModel`, `focusedHex`, `isRiserUp`, `onSubmit`). C'est un canal, pas un chat : elle montre l'état de l'agent et les mots de l'utilisateur, jamais une transcription.

- **Au repos** : micro, puis légende `agent · voice` (nom de l'espace + « voice »/« listening »), champ, `⇥ tab`, arrêt, compteur.
- **En frappe** (champ au curseur **et** texte non vide) : la légende passe au-dessus, la rangée garde chaque emplacement ; le champ ne change jamais de position dans l'arbre, donc le curseur survit au basculement.
- **Champ** : démarre à `composerMinHeight` (14 pt), grandit d'une ligne par ligne de texte jusqu'à `composerMaxHeight` (42 pt = 3 lignes), puis défile. Pendant un riser la limite tombe à `composerMaxHeightWhileRiserUp` (28 pt = 2 lignes) — c'est `HarnessMetrics.composerLimit(riserUp:)`. Une ligne de statut partage la barre et retire une ligne de plus.
- **Champ masqué** : une carte opaque posée par-dessus la barre (diff, jauge, panneau d'intégration, **popup Threads**) la prive du clavier : `VoiceBarView` reçoit `isObscured` et désactive le champ (`composerObscured`), et **résigne le focus** dès qu'une carte s'ouvre — `.disabled` arrête les frappes mais ne rend jamais le premier répondeur, donc sans cette résignation le champ gardait les touches, y compris l'Entrée qui envoie, et `sendAction(cancelOperation:)` lui arrivait au lieu de la carte : Échap n'aurait jamais atteint son `.onExitCommand`. Un riser ne masque rien : il vit *dans* la carte, au-dessus du champ.
- **Suggestion** : en gris italique `#8A8F98` sur l'origine du curseur, seulement si le champ est vide et qu'aucun run n'est en cours. Tab ou → accepte **uniquement champ vide** ; Entrée envoie, Maj+Entrée insère un saut de ligne ; Entrée est lue sur l'**insertion** d'un `\n` (`TextEditor` n'a pas d'`onSubmit`), ce qui laisse l'IME honnête : un Retour qui ne fait que valider du texte composé n'insère rien et n'envoie donc rien. Envoi vide = no-op.
- **Micro** : push-to-talk, sans reconnaissance vocale (le `TODO(STT)` est porté par `VoiceHarnessModel.toggleListening()`). Il bascule l'état `listening`, la forme d'onde 9 barres et la pulsation. Aucune transcription n'est inventée.
- **Stop / compteur / modèle** : visibles seulement pendant un run. Arrêt = SIGTERM de l'enfant (`OpenCodeRunRegistry`) ; le compteur lit les jetons et le coût rapportés par l'agent **à la sortie du processus** — `--format json` est lu en entier au `terminationHandler`, il n'y a pas encore de flux incrémental, donc le compteur affiche `measuring…` pendant le run puis les totaux d'un coup ; une pastille monospace donne le modèle qui travaille (`VoiceHarnessModel.contextModel`, soit **`AppState.opencodeChatModel`** — surtout pas `activeChatModel`, qui est l'alias du fournisseur de chat choisi, `claude-sonnet-4-6` par défaut : le harness lance toujours la CLI OpenCode, qui attend un id `fournisseur/modèle`, et `OpenCodeChat.chat` lit le même `opencodeChatModel` pour cette raison). La maquette ne prévoit pas de pastille de modèle : elle chevauche donc le compteur, uniquement pendant un run, pour ne rien ajouter à la barre au repos qu'elle spécifie.

### Riser (permission / question)
Depuis 0.1.8, **la vue `approval` rend le harness lui-même** (`IslandView.isHarnessSurface`) : une permission ne remplace plus le corps de l'île par une carte, elle s'affiche en ligne au-dessus de la barre vocale — c'est tout l'intérêt de Step 6, la carte ne change jamais de taille. `ApprovalView` n'est donc plus atteignable ; la vue `question`, elle, garde sa carte livrée (`QuestionView`) car une bande de 26 pt ne peut pas exprimer « Other… » ni plus de trois options, et une question doit toujours pouvoir être répondue. Le strip de question du harness reste néanmoins implémenté (Step 6) pour le cas d'un harness au premier plan avec une question encore en attente — route que le routage actuel ne produit pas, puisque `HookServer` force `state.view = .question` à l'arrivée ; quand la bande manque de place, « More… » rend la main à `QuestionView` (`VoiceHarnessModel.showFullQuestion()`), jamais à un second chemin de décision.
`HarnessRiserStrip` est une bande locale compacte, pas la `ApprovalView` livrée (dont le `.padding(.leading, 116)` et la `CardBackground` ne tiennent pas dans 26 pt). La commande y tient sur une ligne tronquée au milieu, avec la commande complète en infobulle. Ambre `#F5A524` pour une permission, violet `#8B5CF6` pour une question. Les boutons passent par `VoiceHarnessModel.resolveApproval(_:)` / `resolveQuestion(_:)`, c'est-à-dire **la même voie de décision unique** (`HookServer.sendApprovalDecision(_:)` / `sendQuestionAnswers(_:)` via `AskQuestion.buildAnswers`) : le harness n'ouvre pas de second chemin. « Always » est masqué pour `agent_codex`, comme dans `ApprovalView`.

### Routage et exécution
`WorkspaceRouter` derrière le protocole `WorkspaceRouting` ; `KeywordRouter` est l'implémentation livrée (pur, testé par `scripts/test-workspace-routing.sh`). Un envoi part vers l'espace de travail au focus si le routage est confiant ; sinon `VoiceHarnessModel.submit()` affiche « Which workspace? Name one — or tap its Mochi. » et **ne lance rien** (on demande au lieu de deviner). Un run déjà en cours bloque un second envoi. L'exécution passe par `OpenCodeChat.run(prompt:model:cwd:runId:)` avec `cwd` = dossier de l'espace (`AgentTask.sessionCwd`), et les totaux de jetons/coût remontent dans `OpenCodeRunResult`.

### Threads (popup horloge)
`ThreadStore` est **en mémoire** par espace de travail (`HarnessThread`), sans persistance ni point de reprise profond : le bouton horloge ouvre `ThreadHistoryPopup`, et « rewind » restaure un instantané du fil de l'espace (les étapes capturées à la fin d'un run) — la ligne choisie si le clic vient d'une ligne, sinon le **dernier** instantané. Le popup dessinant une puce rewind sur chaque ligne pourvue d'un instantané, choisir une ligne ancienne restaure bien *cette* ligne et la remonte en tête. Le `+` démarre une nouvelle session ; il refuse sur Main (« Pick a workspace first — tap a small Mochi. »). Toute la logique de `ThreadStore` (âges, titres, instantanés, recherche, rewind ciblé ou non, plafond de 20 fils) est couverte par `scripts/test-thread-store.sh`, compilée par `swiftc` et branchée dans la CI comme les autres suites.

La maquette dessine `.histpop` comme un panneau de ~292 pt suspendu au coin de son île de 912 × ~600. L'île réelle fait 640 × 160 et **rogne son contenu sur `IslandShape`** : un tel panneau serait coupé au milieu d'une ligne. Le popup occupe donc **toute la surface du harness** (620 × 98, `historyPopupWidth` / `historyPopupMaxHeight`), exactement comme la carte diff. Pour que la liste garde de la place, le champ de recherche de la maquette (une rangée à part entière) est **replié sur la ligne d'en-tête** en capsule, et les paddings verticaux sont resserrés : il reste deux lignes de fil entières, le reste défile. Le popup se ferme quand un riser apparaît — il couvre la seule bande qui permet de répondre à une permission.

### Défilé de tâches (overview)
- Créneau masqué ; lignes de 15 pt (`tickerLineHeight`), précédente 10 pt `#5F646D`, courante 10,5 pt `#F5F6F8` moyenne.
- Ligne courante : texte scintillant (dégradé gris → blanc → gris qui balaie en 2,2 s `shimmerPeriod`), empilée vers le bas, ancrée en bas.
- Le défilé ne montre que les deux dernières étapes de la session (précédente + courante) ; à l'ajout d'une étape, tout monte d'une ligne en 450 ms `cubic-bezier(.3,.9,.3,1)` (`tickerRoll`).
- Dans l'app réelle, les lignes = les dernières actions de la session (outil + cible : « Edit Invoice.swift », « Bash npm test ») — `VoiceHarnessModel.tickerLines`.

### Diff en direct

Quand une étape du fil est une modification de fichier (préfixe interne `\u{E001}`), elle s'affiche avec le nom du fichier et le bilan `+N −M` en couleur. Dans le défilé livré (`TickerView`, utilisé par les cartes d'intégration), un clic sur la ligne courante ou la ligne précédente ouvre la carte diff — que la pastille soit intégrée (integration_claude, agent_cursor…) ou non ; Échap ou le bouton ← de l'en-tête la ferme.

Sur le harness, le défilé est en lecture seule (`HarnessTickerView` ne prend que des lignes) : la carte diff s'ouvre au clavier avec ⌘E (`IslandWindowController` publie `.islandToggleDiff` quand `state.view == .overview`) et `HarnessVoiceView` la présente **par-dessus toute la surface** — `CardBackground` puis `DiffCardView`, la carte livrée non modifiée — parce que le créneau de la carte gauche ne fait que ~30 pt. La carte `ClaudePlanCardView` (build GitHub) se présente pareillement quand la pastille de plan de l'en-tête bascule `showingPlanDetail`. En fin de tâche (Stop), la ligne courante du fil passe en texte statique (couleur `#C9CDD4`, sans brillance) tant que la tâche n'est pas relancée ; elle est construite à partir du dernier message de l'assistant (champ `last_assistant_message` de l'événement Stop, nettoyé du Markdown par `DiffEngine.toOneLine` — premier paragraphe utile uniquement).

### Pastilles (carte droite du harness)
- Grille 2×2 (deux colonnes `flexible`), pastille de 26 pt de haut, rayon 13, écart 4. Fond couleur de l'espace à 13 %, bord à 32 %, mini-bonhomme Ø 18 (`MiniBotCanvasView`, ou un point plein tant que l'espace n'a pas de session), nom 11 pt + sous-titre 10 pt (`#6B7079`). Deux lignes : nom de l'espace et ce qu'il fait (outil courant, sinon dossier, sinon état).
- Anneau giratoire bleu `#3B9EFF` (`pillRingSpin`) pendant que l'agent travaille ; au focus, bord pleine couleur + halo (`glowOpacity`), animés sur `springFast`.
- Chip **Main** : capsule 9 pt dans l'en-tête. Un tap donne le focus à Main ; un second tap (`returnFromMain()`) rend la parole au dernier espace utilisé.
- Seuls les 4 premiers espaces de travail sont affichés (`realWorkspaces.prefix(4)`), Main n'occupe jamais une place de la grille.


### Catalogue de pastilles
Toutes les pastilles déclarées sont définies dans `PillCatalog.all` (source de vérité unique). Quatre catégories :

| Catégorie | Titre | Pastilles | Subtitle (repos) | Subtitle (session) |
|---|---|---|---|---|
| `workspace` | Where you code | VS Code, Cursor, Antigravity *(GitHub only)*, Codex *(GitHub only)*, OpenCode *(GitHub only)* | Integration | Claude Code / Cursor / Codex / OpenCode / Agent |
| `agent` | Agents | Gemini CLI *(GitHub only)* | Agent | Agent |
| `ai` | AI for the chat | Anthropic, Google AI, OpenAI, Ollama, LM Studio | Chat | — |
| `service` | Services | Resend, n8n, Vercel, GitHub, Notion, Cal.com, Stripe, Apple Music *(GitHub only)* | Integration | — |

Couleurs : Cursor `#C0C4CC`, Codex `#2DD4BF`, OpenCode `#FF6A3D`, Gemini CLI `#8AB4F8`, Antigravity `#E879F9`, pastilles IA = `ChatProvider.accentHex` (Ollama `#FACC15`, LM Studio `#A3E635`).

Règles :
- **`mainPillId`** (défaut `integration_claude`) est la pastille workspace toujours chargée. Elle ne compte pas dans les 4 places. Modifiable via le sélecteur Main dans Settings.
- Quand `mainPillId != "integration_claude"`, la pastille VS Code est chargée seulement si une session VS Code est active (transient) ou si elle est cochée dans `activeIntegrations`.
- Max 4 pastilles autres que `mainPillId` actives à la fois (`activeIntegrations`, persisté).
- `removeTask` sur `mainPillId` ou une pastille déclarée + active → reset à `.idle` + `pillBadge = nil` + nom du catalogue (pas de suppression). Sinon → suppression normale.
- `sortTasksByCatalog` : pastilles du catalogue dans l'ordre du catalogue ; pastilles hors catalogue juste après `integration_claude`.
- Pastilles `githubOnly` : exclues des builds App Store (`#if APPSTORE`).
- Hooks (Gemini CLI, Antigravity, Codex) : `isConfigured` = `HookServer.geminiHooksInstalled()` / `agyHooksInstalled()` / `codexHooksInstalled()` sous `#if !APPSTORE`. La section Codex Hooks dans Settings installe les hooks dans `~/.codex/hooks.json` avec le même flux backup + preview que Gemini CLI. Après l'installation, la carte affiche : « run /hooks in Codex or open Hooks in the app's settings to trust them ». Approbations Codex : carte avec Allow et Deny seulement (pas Always) ; updatedPermissions jamais envoyé ; notes « Handled in Codex. » / « Still waiting in Codex. ».
- Plugin (OpenCode) : `isConfigured` = `HookServer.opencodeHooksInstalled()` (`~/.config/opencode/plugins/coucou.ts` ou `.js`) sous `#if !APPSTORE`. La section OpenCode Plugin dans Settings installe le plugin embarqué (`OpencodePluginSource.swift`, miroir de `opencode/coucou.ts`) avec backup `.bak-<date>` avant écrasement. Carte : « Plugin installed » / « Plugin not installed » (jamais « Hooks … »). Approbations non supportées (comme Gemini/Antigravity).
- Pastilles IA (cloud) : `isConfigured` = clé API dans le Keychain. Pastilles IA locales (Ollama, LM Studio) : `isConfigured` = URL serveur non vide (définie via le bouton **Connect** dans Réglages → Chat). Bouton « Chat with… » → change le fournisseur et ouvre la vue `.prompt`.

### Carte GitHub (`GitHubPulseCardView`)

Affichée à la place de `GitHubStatsCardView` quand un `GitHubPulse` est disponible (`githubPulse != nil`). Trois lignes `GitHubStatRow` (My PRs, To review, Default branch CI), chacune tappable → ouvre `GitHubDetailView` avec la section correspondante. En-tête : point rouge + « GitHub » + bouton « ★ N.Nk » (étoiles) + rangée de 7 carrés de contribution (7 derniers jours, 7 pt, espacement 2 pt) si `githubActivity != nil` → ouvre la section `.activity`. Sans stats : « Overview ».

### Vue détail GitHub (`GitHubDetailView`)

Remplace la carte principale quand `showingDetail && githubHasPulse`. En-tête : chevron.left (← ferme) + titre de section. Sections **My PRs**, **To review** → `GitHubPRRowView` (point CI + « repo#N » + titre tronqué + badge Draft), ScrollView maxHeight 60 pt (3 lignes × 20 pt), fondu bas si > 3 éléments. Section **Default branch CI** → `GitHubRepoCIRowView` (point CI + nom court + branche + état). Clic sur une PR → ouvre `https://github.com/…` (filtré `host == "github.com"`). Échap ferme.

### Section Activity (`GitHubActivityDetailContent`)

Section `.activity` de `GitHubDetailView`. En-tête : chevron.left + « Activity » à gauche ; à droite (11 pt #8E939C) : « 1,234 past year · N repos » (clic → `github.com/<login>`). Au survol / clic sur un carré : texte remplacé par « Oct 3 · 12 contributions » (ou « 1 contribution », ou « No contributions »). Grille de contributions : colonnes = semaines (la plus ancienne à gauche, carrés de 7 pt, espacement 1,5 pt, nombre de semaines calculé selon la largeur disponible, environ 23), lignes = jours de la semaine (dimanche = ligne 0). Couleurs des niveaux : 0 = blanc 6 %, 1 = `#0E4429`, 2 = `#006D32`, 3 = `#26A641`, 4 = `#39D353`. Pas de ScrollView, `.clipped()`. `refreshActivityIfStale()` à l'apparition.

### Boutons
- Pilule, 12,5 pt medium, fond blanc 9 % (survol 15 %), primaire : fond `#F5F6F8` texte `#0B0C0E`. Appui : échelle 0,94. Raccourcis affichés en petite pastille bordée (Y, N).

## 6. Couleurs des agents (fixes)

| Agent | Couleur |
|---|---|
| Korus | `#FF6B5B` |
| SBE Hub | `#2DD4A7` |
| Morning AI Brief (n8n) | `#F7B32B` |
| Publication IG (n8n) | `#A78BFA` |
| louisraille.fr | `#38BDF8` |
| Autres | prendre dans cet ordre : `#F472B6`, `#34D399`, `#FB923C`, `#60A5FA`, `#E879F9`, puis boucler |

Nom d'une session Claude Code = nom du dossier de travail (`cwd`), avec une table d'alias réglable (ex. `sbe-hub` → « SBE Hub »). Nom d'un workflow n8n = nom du workflow.

## 7. Le personnage : Mochi

Porter la classe `Bot` du prototype **telle quelle** en Swift (`Canvas` dans `TimelineView(.animation(paused:))`). Constantes Mochi (`PISTES.mochi`) :

- R = 0,3 × côté du canvas. Corps : superellipse d'exposant 2,7, rayons rx = 1,14 R, ry = 0,88 R, décalé de +0,06 R vers le bas.
- Dégradé du corps : `#FFFAF5` (haut droite) → `#DDCCBF` (bas gauche). Teinte d'état : dégradé linéaire de bas en haut, couleur d'état à 92 % × tint jusqu'à transparent à −0,25 ry. Ombrage radial (bord 20 % noir) et reflet radial blanc 55 % en haut à droite.
- Joues : deux ellipses rose `rgba(255,120,150,.5 × blush)`, blush minimum 0,35 pour Mochi, suivent le regard.
- Yeux : encre `#1A1412`, largeur 0,25 R, hauteur 0,27 R, écart angulaire ±0,37 rad, inclinaison verticale −0,12 rad. Projection sur une sphère (yaw, pitch, roll) avec raccourci de perspective et découpe par la silhouette : c'est ce qui donne les roulades (les yeux sortent par le haut et reviennent par le bas).
- Regard : suit la souris avec retard (`tanh(dx/260)`, `tanh(dy/200)`, lissage exponentiel). Clignement aléatoire toutes les 2,2 à 5,4 s, double clignement 22 % du temps.
- Mini-bonhommes : même moteur, corps teinté de la couleur de l'agent, badges réduits.
- Canvas du gros bonhomme : 230 pt × 2 (Retina) ; mini : 76 pt × 2.

### États (`STATES`)

| Clé | Libellé | Couleur | Teinte | Yeux | Badge | Particularité |
|---|---|---|---|---|---|---|
| `idle` | Au repos | `#E6E9EE` | 0 | pilule | aucun | |
| `working` | Travaille | `#3B9EFF` | 0,72 | pilule | pilule « ••• » animée | |
| `thinking` | Réfléchit | `#8B5CF6` | 0,72 | pilule | « ••• » | regarde en haut à droite |
| `searching` | Cherche | `#6366F1` | 0,72 | pilule | « ••• » | yeux qui balaient de gauche à droite |
| `approval` | Attend ton feu vert | `#F5A524` | 0,78 | grands | « ! » | petits sauts en boucle |
| `question` | Pose une question | `#22D3EE` | 0,75 | pilule | « ? » | tête penchée 0,17 rad |
| `error` | Erreur | `#F4505E` | 0,78 | plats | point rouge | secousse horizontale à l'entrée |
| `finished` | Terminé | `#34D399` | 0,35 | contents (arc) | point vert | roulade complète 950 ms + étincelles |
| `ratelimit` | Limite atteinte | `#FB923C` | 0,72 | fatigués | point orange | gouttes de sueur |
| `sleeping` | Dort | `#94A3B8` | 0,32 | fermés | aucun | respiration, « z » qui montent |
| `dizzy` | Sonné | `#F472B6` | 0,7 | spirales | aucun | double roulade 1,3 s |

Halo derrière le bonhomme : dégradé radial couleur de l'état, opacité 0,2 à 0,6 selon l'état (`glow`, `go`), flou 6.

Correspondance avec les vrais événements : voir `INTEGRATIONS.md`. `sleeping` = aucune tâche depuis 10 min et island ouverte manuellement ; `ratelimit` = limite d'usage signalée par Claude Code.

### Émotes (`EMOTES`) et déclencheurs réels

| Émote | Yeux | Extra | Son | Déclencheur |
|---|---|---|---|---|
| Amour | cœurs `#FF4D6D` | joues à fond, cœurs qui montent | `love` | souris immobile 1,9 s sur le bonhomme |
| Surpris | petits points | saut + yeux agrandis | `pop` | quand on l'attrape |
| Fier | étoiles `#F7B32B` | étoiles, tête en arrière | `proud` | résultat de recherche affiché |
| Clin d'œil | un œil fermé | tête penchée | `wink` | mail envoyé, fenêtre attrapée |
| Bâille | fatigués puis fermés | étirement vertical, « z » | `yawn` | juste avant de passer en `sleeping` |
| Content | arcs | joues | — | après une décision, un fichier avalé |
| Agacé | fentes inclinées | halo violet `#A855F7` | `annoyed` | une claque |

## 8. Interactions avec le bonhomme

- **Survol** (expanded) : clignement, yeux ×1,08, son `hover`. Immobile 1,9 s → Amour.
- **Clic** en compact/peek → ouvre. **Clic** en expanded → claque : écrasement (70/130/170 ms), Agacé 800 ms, halo violet, sons `slap` + `annoyed`.
- **3 clics en moins de 1,7 s** → état `dizzy` pendant 3,3 s, vue `confused`, son `dizzy`, puis retour à la vue et à l'état d'avant.
- **Glisser** le bonhomme (> 7 pt) : un bonhomme flottant Ø 54 suit le curseur (Surpris + `pop`), celui du notch disparaît. Lâché sur une fenêtre d'une autre app → **attache** (voir INTEGRATIONS §4). Lâché ailleurs → revient dans le notch en 420 ms en rétrécissant.
- **Glisser un fichier** depuis le Finder vers la zone du notch (±220 pt autour du centre, jusqu'à 26 pt sous l'island) → vue `upload`, le bonhomme se transforme en « bac » (morph 380 ms avec rebond) et regarde le fichier. Contour vert et voile vert quand le fichier est au-dessus.
- **Déposer** : le fichier file dans le bonhomme (360 ms), `gulp` à 330 ms, écrasement + Content, retour à la forme ronde à 950 ms, vue `uploading` (1,2 à 2,1 s, `tick` tous les 10 %, correspond à la copie dans le dossier de travail de l'app), son `approve`, puis vue `choose`.
- Plusieurs fichiers : même flux, libellé « 3 fichiers ».

## 9. Sons

Fichiers `assets/sounds/*.wav` (48 kHz stéréo), rendus depuis le moteur du prototype avec un gain ×6. **Volume par défaut du lecteur : 0,12** pour retrouver le niveau du prototype ; le curseur de volume des réglages va de 0 à 0,2. Jouer avec `AVAudioPlayer` préchargés (latence nulle), plusieurs sons peuvent se superposer. Désactivable dans l'en-tête de l'island et dans les réglages (persisté).

| Événement | Son |
|---|---|
| peek / coucou | `peek` + `greet` |
| ouverture / fermeture | `open` / `close` |
| survol du bonhomme / petit clic UI | `hover` / `blip` |
| claque / agacé / sonné | `slap` / `annoyed` / `dizzy` |
| travaille / réfléchit / cherche | `work` / `think` / `search` |
| permission / question / erreur / limite | `approval` / `question` / `error` / `rate` |
| terminé | `finish` |
| décision validée, upload fini | `approve` |
| fichier avalé / progression | `gulp` / `tick` |
| envoi (prompt, mail) / attache fenêtre | `send` / `attach` |
| émotes | `love`, `pop`, `proud`, `wink`, `yawn`, `sleep` |

Pas de son pour les mises à jour silencieuses (défilé de tâches, mini-bonhommes qui changent d'état sauf alerte).

## 10. Barre de menus et réglages

Petit item dans la barre de menus (icône : silhouette du Mochi, monochrome). Menu : Ouvrir le notch, Lancer la démo (⌃⌥⌘D), Réglages…, Debug ▸ (forcer chaque vue, chaque état, chaque émote, ajouter des tâches factices), Quitter.

Fenêtre Réglages (SwiftUI, simple), sections dans l'ordre d'affichage :
- **Anthropic API** : clé (Trousseau), modèle (défaut `claude-sonnet-4-6` ; liste depuis l'API, voir INTEGRATIONS §5).
- **Chat — other providers** : clé Google AI (Trousseau) ; clé OpenAI (Trousseau). Les modèles se choisissent dans le chat (voir INTEGRATIONS §5bis).
- **Local models** : URL du serveur Ollama (défaut `http://127.0.0.1:11434`) et/ou LM Studio (défaut `http://127.0.0.1:1234`). Bouton **Connect** : vérifie la joignabilité et sauvegarde l'URL. Bouton **Disconnect** : efface l'URL et le cache. Aucune clé requise (voir INTEGRATIONS §5ter).
- **Claude Code Hooks** : état des hooks, bouton Installer / Désinstaller.
- **Gemini CLI Hooks** *(build GitHub)* : état des hooks, bouton Installer / Désinstaller.
- **Antigravity Hooks** *(build GitHub)* : état des hooks, bouton Installer / Désinstaller.
- **Codex Hooks** *(build GitHub)* : état des hooks, bouton Installer / Désinstaller (`~/.codex/hooks.json`, flux backup + preview).
- **OpenCode Plugin** *(build GitHub)* : état du plugin, bouton Install plugin / Uninstall (`~/.config/opencode/plugins/coucou.ts`, source embarquée).
- **Plan usage** : toggle **Show in the notch** + bouton **Install relay** / **Uninstall relay**. Voir INTEGRATIONS §1bis. **Jauge de forfait Claude** *(GitHub only)* : petit pill dans l'en-tête de l'île (vue home uniquement). Activé via `showPlanInNotch` (UserDefaults) + `HookServer.statusLineInstalled()`. Couleur = `ClaudePlanGauge.color(for: dominantPct)`. Clic → `showingPlanDetail` bascule et `ClaudePlanCardView` s'affiche à la place de la carte en cours. `showingPlanDetail` se remet à false au changement de focusId, de vue ou de mode. Grand Mochi prend la couleur de l'usage quand `showingPlanDetail == true`.
- **Integrations** : clé ou token (Trousseau) pour chaque service (n8n, Stripe, GitHub, Vercel, Resend, Notion, Cal.com).
- **Sound** : son on/off, volume.
- **Behavior** : fermeture après N s d'inactivité ; masquage après N min sans mouvement.
- **Active pills** : pastilles actives (VS Code toujours actif + jusqu'à 4 autres) ; sélecteur de pastille principale (affiché uniquement si une pastille workspace est active) ; liste par catégorie (voir catalogue §5).
- **Hotkey** : raccourci global pour ouvrir le notch.
- **Startup** : lancer au démarrage (`SMAppService.mainApp`).

### Garde-robe (`WardrobeView`)

Accessible par clic droit sur la tête de Mochi (étendu ou compact). L'île s'étend sur `.wardrobe`.

**Mise en page** : Mochi à gauche (même position qu'overview, avec la tenue survolée en aperçu direct). À droite : en-tête « Wardrobe » 12 pt semibold + la tenue sélectionnée en 11 pt #8E939C. Si Auto : « Auto · Witch hat » (tenue de saison actuelle).

Grille de pastilles 30 pt, coins 7 pt, fond blanc 6 %, bord blanc 8 % (sélectionnée : 40 %). Chaque pastille affiche l'accessoire dessiné en Canvas statique. La pastille **Auto** porte un badge « AUTO » en 8 pt ; au survol, l'en-tête de droite affiche le nom de la tenue de saison (ou « None » si aucune). Survol : fond 10 % + aperçu sur Mochi. Clic → sélectionne, sauvegarde, son « pop », émote proud.

**Affichage de la tenue** : la tenue n'est visible sur le gros Mochi que quand `focusId == mainPillId` (ou `focusId == nil`), ou quand l'île n'est pas en mode expanded, ou quand la vue active est `.wardrobe`. Dans tous les autres cas (focus sur une autre tâche en expanded), Mochi porte `.none`.

**Transitions** : chaque accessoire dispose d'une valeur `presence` (0 → 1, animée en 350 ms `Ease.inOut`). À l'entrée, la position est interpolée avec `Ease.back` (légère surcourse). Chaque accessoire est dessiné dans un calque dédié (`GraphicsContext.drawLayer`) pour éviter les transparences parasites entre formes superposées ; opacité du calque = `min(1, presence × 2.5)`. Déplacements typiques à l'entrée : chapeaux descendent de 1,0 ry ; oreilles montent ; écharpe et nœud émergent de leur position de repos.

**Physique** : `physDx` et `physDy` (ressort ω₀ ≈ √60 rad/s, ζ ≈ 0,6) suivent la vélocité du yaw (décalage horizontal) et du bounce (décalage vertical). Impulsions supplémentaires : `physVy += 0,6` lors d'un écrasement (`squash`) ; force centrifuge `rollVel × 0,18` ajoutée à la cible de `physDx` pendant la roulade avec tenue.

**Roulade** : quand Mochi porte une tenue (`outfit != .none`, `outfitPresence > 0,05`), la roulade est **rigide** — tout Mochi (mains derrière, accessoires, corps, yeux, mains devant) est dessiné dans un contexte tourné de `roll` autour du centre du corps. Les accessoires utilisent une projection sans roll (`H.roll = 0`) et restent posés sur la tête ; ils co-tournent via le contexte. Particules et badge sont dessinés hors du contexte tourné. Quand aucune tenue n'est portée, la roulade originale s'applique (illusion sphérique par les yeux uniquement).

**Fermeture** : Échap, clic maison, ou clic droit sur Mochi à nouveau.

**Référence visuelle** : `design/outfits/` (`mochi-outfits.js`, `sheet.html`, `mochi-outfits-reference.png`). Outil de développement : `scripts/render-outfits.sh` (hors CI) — génère `/tmp/coucou-outfits.png`, `/tmp/coucou-roll.png`, `/tmp/coucou-transition.png`.

**Calendrier des saisons** (mode Auto) :
- 1 oct – 1 nov : Witch hat
- 1 déc – 26 déc : Santa hat
- 31 déc – 2 jan : Party hat
- Pâques −2 / +1 : Bunny ears
- 21 juin – 31 août : Sunglasses

**Identifiants stables** (UserDefaults key `mochiOutfit`) :
`auto`, `none`, `partyHat`, `beanie`, `crown`, `witchHat`, `santaHat`, `bunnyEars`, `bow`, `sunglasses`, `roundGlasses`, `scarf`, `pumpkin`

Les valeurs supprimées (`topHat`, `cap`, `heartsHeadband`, `strawHat`) sont migrées vers `auto` à la lecture.

## 11. Jalons

Chaque jalon se termine par build + capture + comparaison aux références + commit (voir CLAUDE.md).

- **M0 Base** : vérifier Xcode (`xcodebuild -version`), XcodeGen, `git init`, `project.yml`, app agent qui se lance et affiche le faux contenu. Menu Debug.
- **M1 Island** : panel, détection du notch, 4 modes, règles §3, clics traversants, animations §4, données factices.
- **M2 Personnage** : port de `Bot` (Mochi), tous les états et émotes, mini-bonhommes, halo, badges, particules, mains. Pause quand masqué.
- **M3 Vues** : toutes les vues §5, défilé, pastilles, colonne, élément partagé, voiles. Comparer avec les 16 captures.
- **M4 Sons** : branchement §9, réglages son.
- **M5 Claude Code** : hooks, approbations, questions, saut au terminal (INTEGRATIONS §1).
- **M6 n8n** : polling, erreurs, relance, ouverture (INTEGRATIONS §2).
- **M7 Fichiers** : glisser-déposer, prompt sur fichier, mail via Mail (INTEGRATIONS §3 et §6).
- **M8 Fenêtres + recherche** : attache, capture, URL, API Claude avec recherche web, vue résultat (INTEGRATIONS §4 et §5).
- **M9 Finition** : mode démo (DEMO.md), réglages complets, lancement au démarrage, écran sans notch, mesure CPU/RAM, passe finale de comparaison visuelle.

## 12. Critères d'acceptation

- Côte à côte avec le prototype, Louis ne voit pas de différence sur le personnage, les couleurs, les timings et les sons.
- Aucun clic perdu à cause de la fenêtre transparente.
- Une session Claude Code n'est jamais bloquée par l'app (app fermée, plantée ou lente → le terminal prend le relais).
- Hidden = 0 % CPU ; compact < 3 % ; mémoire < 100 Mo.
- La démo (⌃⌥⌘D) se filme d'une traite sans intervention.

## 13. Mochi sur le bureau

Mochi peut quitter l'island et vivre comme une icône flottante sur le bureau. Il conserve tout son comportement (tenue, émotes, suivi des yeux, danse) et réagit aux alertes.

### Pose et panneau

- **Panneau** : `NSPanel` borderless non-activating, niveau `.floating`, `collectionBehavior [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]`, taille 120 × 120 pt.
- **Clics traversants** : `ignoresMouseEvents` activé par défaut ; désactivé à 60 Hz uniquement quand le curseur est sur le corps (rayon ≈ 24 % de la taille du panneau). Position bornée à `screen.visibleFrame` avec une marge de 24 pt.
- Le panneau est toujours au niveau `.floating` — en dessous des panneaux de menu et de l'island, au-dessus des fenêtres normales.

### Installation

- **Depuis le glisser** : quand l'utilisateur lâche Mochi hors de la zone notch et hors de toute fenêtre, `IslandWindowController.finishDrag` cède le panneau fantôme au `DesktopMochiController`. Le panneau s'agrandit vers 120 × 120 (animation ressort ~0,25 s), son contenu remplacé par `DesktopBotView`. Son de bienvenue : `pop`. Atterrissage avec émote `happy`.
- **Retour dans la zone notch** : lâcher dans le cadre du panneau island → Mochi retourne à la notch sans s'installer sur le bureau.
- **Au démarrage** (si `UserDefaults["mochiOnDesktop"] == true`) : le greeting se joue normalement, puis à `greetComplete` un nouveau panneau part de la notch et vole vers la position sauvegardée (animation 0,45 s).

### Interactions

| Geste | Effet |
|---|---|
| Clic simple | Slap (`engine.slap()`) — différé de `NSEvent.doubleClickInterval` |
| Double-clic | Annule le slap en attente ; vol vers la notch (`flyHome()`), island réapparaît |
| Clic droit | Ouvre/ferme la garde-robe (`.openWardrobeFromDesktop`, sans `.hookExpand`) |
| Glisser → zone notch | Vol vers la notch (`flyHome()`) |
| Glisser → fenêtre (GitHub) | Attache le contexte, Mochi revient à sa position initiale, island ouvre `.prompt` |
| Glisser → ailleurs | Repositionne le panneau (borné au `visibleFrame`) |

### Personnage complet

- Respiration, clignements, suivi des yeux depuis la position du panneau (pas depuis l'island).
- Tenue : toujours celle de `state.resolvedOutfit` (main Mochi = toujours habillé).
- Danse : mêmes règles que le mode compact (musique + intégration active + état autorisé).
- 30 fps actif, 10 fps au repos (`TimelineView` adapte `minimumInterval` selon `isSleeping`).

### Absences de la notch

Quand `AppState.mochiOnDesktop == true`, `BotPlacement` masque le bonhomme de la notch (opacité 0, même règle que `isDraggingBot`).

### Alertes

Détection par `Publishers.CombineLatest($pendingApproval, $pendingQuestion)` — seules les transitions nil↔non-nil déclenchent l'action. La notification `.hookExpand` n'est pas utilisée (elle part aussi pour `.finished`, `.error`, le glisser de fichier, etc.).

1. `pendingApproval` ou `pendingQuestion` passe à non-`nil` → émote `surprised` sur le Mochi du bureau.
2. Après 0,45 s, `retractForAlert()` : le panneau vole vers la notch et se ferme ; `mochiOnDesktop` passe à `false` (le bonhomme de la notch réapparaît pour l'alerte) ; `UserDefaults["mochiOnDesktop"]` reste `true`.
3. Quand `pendingApproval` **et** `pendingQuestion` sont tous deux `nil`, `launchFlyIfNeeded()` renvole Mochi vers la position sauvegardée après 0,6 s.
4. Si l'alerte se résout pendant l'animation de retrait, le panneau ne s'ouvre pas sur la notch — Mochi repart directement vers le bureau.

### `.finished`

Émote `happy` (saut de joie) sur le Mochi du bureau. Détecté par `Publishers.CombineLatest($stateOverride, $tasks)` → `effectiveState` ; ne déclenche pas de retrait vers la notch.

### Sommeil

- 2 min sans activité d'agent ET souris à plus de 150 pt → `engine.setState(.sleeping)`, `TimelineView` passe à 10 fps.
- Réveil à l'approche de la souris ou à la réception d'un événement d'agent.
- Pause complète lors du sommeil écran (`NSWorkspace.screensDidSleepNotification`) ou du verrouillage de session (`com.apple.screenIsLocked`).

### Persistance

- Position et état sauvegardés dans `UserDefaults` (clés : `desktopMochiX`, `desktopMochiY`, `mochiOnDesktop`).
- Position bornée au `visibleFrame` du meilleur écran disponible au chargement ; si aucun écran ne convient, coin bas-droit de l'écran principal avec 24 pt de marge.


## 14. Raccourcis clavier

### 14.1 Raccourcis globaux (Carbon `RegisterEventHotKey`)

Ces raccourcis fonctionnent en arrière-plan sans permission Accessibilité.

| Action | Défaut | Clé UserDefaults | Activé par défaut |
|--------|--------|-----------------|-------------------|
| Afficher/masquer l'île (`toggleIsland`) | ⌘⇧N | `hotkeyCode` / `hotkeyFlags` (legacy) | Non |
| Ouvrir le chat (`openChat`) | ⌃⌥Espace | `shortcut.openChat.keyCode` / `.flags` | Oui |
| Aller à l'alerte (`goToAlert`) | ⌃⌥A | `shortcut.goToAlert.keyCode` / `.flags` | Oui |
| Sauter au terminal (`jumpToTerminal`) | ⌃⌥T | `shortcut.jumpToTerminal.keyCode` / `.flags` | Oui |
| Attacher la fenêtre active (`attachFrontWindow`) | ⌃⌥W | `shortcut.attachFrontWindow.keyCode` / `.flags` | Oui (hors App Store) |
| Pilule suivante (`nextPill`) | ⌃⌥] | `shortcut.nextPill.keyCode` / `.flags` | Oui |
| Pilule précédente (`prevPill`) | ⌃⌥[ | `shortcut.prevPill.keyCode` / `.flags` | Oui |
| Couper le son (`toggleMute`) | ⌃⌥M | `shortcut.toggleMute.keyCode` / `.flags` | Oui |
| Mochi sur le bureau (`toggleDesktopMochi`) | ⌃⌥D | `shortcut.toggleDesktopMochi.keyCode` / `.flags` | Oui |
| Ouvrir la garde-robe (`openWardrobe`) | ⌃⌥G | `shortcut.openWardrobe.keyCode` / `.flags` | Oui |

- Si Carbon ne peut pas enregistrer un raccourci (conflit système), l'action est marquée `.conflict` dans `HotKeyCenter` et un indicateur apparaît dans Réglages → Raccourcis.
- `toggleIsland` conserve les clés UserDefaults historiques (`hotkeyCode`, `hotkeyFlags`, `hotkeyEnabled`) pour ne pas casser les préférences existantes.
- Les actions marquées `isNonAppStore` (`attachFrontWindow`) sont omises du build App Store.

### 14.2 Raccourcis locaux (actifs quand l'île a le focus)

Ces raccourcis sont gérés par `NSEvent.addLocalMonitorForEvents`. L'île prend le focus clavier quand elle est ouverte via un raccourci global (jamais au survol ni à l'alerte).

| Raccourci | Action |
|-----------|--------|
| ⌘→ | Pilule suivante |
| ⌘← | Pilule précédente |
| ⌘1…⌘9 | Passe directement à la pilule n° 1–9 |
| ⌘↓ | Descend dans la liste de la carte active |
| ⌘↑ | Monte dans la liste de la carte active |
| ⌘O | Ouvre/développe l'élément sélectionné |
| ⌘E | Afficher/masquer le diff (vue `overview`) |
| ⌘↩ | Envoyer le message (vue Prompt) |
| ⌘K | Nouvelle conversation (vue Prompt) |
| ⌘, | Ouvrir les Réglages |
| ⌘P | Copier le dernier message |
| ⌘⇧D | Afficher/masquer le diff |

### 14.3 Personnalisation

Réglages → Raccourcis (`ShortcutsSettingsView`) :

- Chaque raccourci global dispose d'un toggle (activer/désactiver) et d'un `ShortcutRecorderButton` pour le reconfigurer.
- Les conflits internes (deux actions avec le même raccourci) sont signalés en rouge.
- Les conflits système (Carbon a refusé l'enregistrement) sont signalés en orange.
- Bouton **Tout réinitialiser** remet les valeurs par défaut sur toutes les actions.
- Les raccourcis locaux sont affichés en lecture seule.
