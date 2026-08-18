# Changelog — Mediabot v3

All notable changes to Mediabot v3 are documented here.

Versioning follows the project rule: odd minor versions are stable releases
and even minor versions are development lines. **3.3** is the current stable
release. Development after this release continues on the `3.4dev` line.

---

## mb646 — achievements survive restarts and updates in MariaDB

- Achievements no longer depend on the release-local JSON file once the new DB
  migration is installed. Unlocks and progress are written through to MariaDB.
- Added durable per-channel achievement profiles plus IRC identity aliases. The
  resolver uses the live `(nick, user@host, channel)` tuple conservatively:
  exact triplets first, registered USER id as authoritative proof, exact
  user@host across nick changes, then same-nick aliases only when ident or host
  still matches.
- Existing `var/achievements.json` state is imported once and preserved as a
  `.migrated-<timestamp>` backup. Older deployments that have not applied the
  schema migration retain the JSON fallback instead of losing achievements.
- Message-derived thresholds (`msg_count`, night/early hour bands and
  `polyphony`) aggregate the durable profile's known aliases, so a nick change
  does not reset long-running merit back to zero.
- The updater preserves the legacy JSON during the transition, and startup can
  recover history from the current deployment family's archives: both numeric
  `<root>.NNN` and timestamped `<root>.old.YYYYMMDD_HHMMSS` layouts are
  supported without scanning a sibling bot family under the same Unix home.
- Dashboard and leaderboard code now consume achievement storage through public
  methods instead of reaching into the module's internal hash representation.

## [Unreleased] — 3.4dev

### mb662 — opt-in conservative fast-lane parallel pilot
- Added `t/fast_parallel.pl` as a deliberately separate MB661 acceleration
  experiment. It reuses `--fast --list-selected` as the source of truth instead
  of reimplementing test classification or fast-lane membership.
- Only selected non-sentinel tests whose primary class is `PURE` may overlap.
  The 11 cross-cutting MB661 sentinels always run afterwards in a separate
  serial stage; unexpected non-PURE non-sentinels fail closed.
- The pilot supports two to four jobs, deterministic plan-only inspection and
  an optional aggregate assertion-count check against a known serial `--fast`
  reference. Every selected fast-lane file must appear exactly once in either a
  parallel shard or the serial sentinel stage.
- Default `t/test_commands.pl`, serial `--fast` and the full suite remain
  unchanged. MB662 is opt-in evidence gathering before any parallel execution
  can be promoted into the normal validation workflow.

### mb661 — deterministic fast validation lane
- Added an explicit `--fast` development-validation lane to
  `t/test_commands.pl`. It selects every test whose mb660 primary class is
  `PURE`, then adds a small reviewed set of cross-cutting sentinels for runner
  isolation, dispatch, startup integrity, profiling/classification and module
  structure.
- The sentinel manifest is fail-closed: if a required sentinel is renamed or
  removed, `--fast` refuses to run instead of silently weakening its coverage.
  `--fast --class-summary` and `--fast --list-selected` expose the exact lane
  without executing it.
- Existing `--filter`, `--class` and `--exclude-class` selectors may further
  narrow the fast lane for diagnosis; they never expand it. Default execution
  with no `--fast` option remains the complete suite.
- The first real-host fast-lane profile showed that `PURE` is not synonymous
  with quick: a small set of timing-heavy PURE tests dominated runtime. MB661
  therefore keeps an explicit profiler-backed slow manifest; those tests stay
  in targeted regressions and the default full suite, while mandatory sentinels
  always override the optimisation manifest.
- The runner labels fast execution explicitly as development validation and
  states that it is **not equivalent to the full suite**. No parallelism,
  reordering or hidden skip mechanism is introduced in mb661.
- Normal development can now combine targeted regression tests with `--fast`,
  while the full suite remains the global checkpoint for cross-cutting changes
  and release validation.

### mb660 — conservative test classification
- Added a reusable test classifier with the roadmap's `PURE`, `FILESYSTEM`,
  `PROCESS`, `DB` and `NETWORK` capability families. Classification is
  deliberately conservative: source touchpoints and isolated-TAP execution are
  recorded even when an external dependency is mocked.
- `t/test_commands.pl` can now select tests with repeatable/comma-separated
  `--class` and `--exclude-class` filters, print a no-execution
  `--class-summary`, or list the exact selected files and their tags with
  `--list-selected`.
- Capability tags may overlap; each file also receives one primary reporting
  class using conservative precedence. These labels are explicitly **not**
  parallel-safety certification, and mb660 adds no jobs/parallel executor,
  reordering or implicit test skipping.
- Default runner behaviour remains the same when no classification options are
  supplied. New regression coverage validates synthetic/real classifications,
  isolated-process tagging, filtering, invalid-class rejection and the
  inspection-only CLI paths.
- This completes the classification foundation requested after the mb650
  profiler so later fast/parallel lanes can be designed from explicit metadata
  instead of blindly parallelising the full suite.

### mb659 — richer `!profil` progression card
- Enriched `!profil` / `!profile` with Achievement progress already persisted by
  the normal feature paths: best activity streak, Night Owl and Early Bird
  message counters, and the longest observed comeback now sit beside the
  existing activity, karma, trivia and 24-hour profile signals.
- Added a single spoiler-safe `Next:` goal using the existing
  `Achievements::next_goals()` ordering. Locked mb658 secret achievements remain
  invisible even when their hidden threshold is closer than every public goal.
- The visible achievement X/Y counter keeps the mb658 secret-denominator rule.
  No new `CHANNEL_LOG` gather or direct profile SQL query is introduced: the
  new values come from `progress_for_nick()` and the already-loaded Achievement
  registry.
- Added regression coverage for the rendered profile, hidden-secret safety and
  the invariant that `!profil` still owns exactly three historical gathers and
  its two pre-existing direct karma/trivia query sites. No schema, migration or
  configuration change is required.

### mb658 — secret achievements
- Added three deliberately hidden legendary achievements that extend counters
  Mediabot already persists: **The Witching Hour** (5,000 night messages),
  **Eternal Flame** (365 consecutive active days) and **Phoenix Rising**
  (returning after at least 365 days away).
- Locked secrets are excluded from `!achievements list`, `!achievements
  progress`, closest-goal suggestions and visible achievement denominators.
  Their name, condition, threshold and progress therefore remain undisclosed
  until the normal unlock announcement reveals them.
- Once unlocked, a secret behaves like any other achievement: it appears in the
  user's achievement view and joins the visible total. `!profil` follows the
  same rule so its X/Y counter cannot leak undiscovered secrets.
- The three secrets reuse `night_messages`, `activity_streak_days` and
  `comeback_days`. The night secret participates in the existing MB657
  hour-band query; streak/comeback reuse their existing checks. No new
  historical scan, table, migration or configuration key is required.

### mb657 — measurable Night Owl ladder
- Turned the existing **Night Owl** (50 messages between 00h-05h) into the
  first measurable rung of a three-level ladder: **Midnight Regular** (250)
  and **Creature of the Night** (1,000) reuse the same `night_messages`
  progress counter. Existing **Early Bird** also becomes measurable through
  `morning_messages`.
- Reused the already-existing hour-band check rather than adding another
  `CHANNEL_LOG` query. One result now feeds both progress counters and all
  hour-based unlock decisions.
- Replaced the historical `GROUP BY HOUR(ts)` path with two conditional
  aggregate sums in one query, avoiding the temporary/filesort grouping while
  preserving the 00h-05h and 06h-08h semantics.
- The mb450 short-circuit now derives its floor from the lowest still-locked
  configurable hour-band threshold instead of hard-coding 50, so lower
  `[achievements]` overrides cannot be accidentally made unreachable.
- The existing one-scan-per-hour throttle remains in place. No table,
  migration or new configuration key is required.

### mb656 — comeback achievements
- Added three user-facing comeback milestones based on the existing `USER_SEEN`
  history: **Welcome Back** (7 days), **Long Time No See** (30 days) and **The
  Return** (90 days). They share the monotonic `comeback_days` progress counter.
- JOIN handling samples the previous `USER_SEEN.seen_at` **before** the normal
  JOIN upsert refreshes it, but stores only a bounded in-memory candidate.
  Merely joining a channel therefore cannot create or touch an Achievement
  profile.
- The candidate is consumed on the user's first public message only after
  mb646 `observe_identity()` has resolved the live nick/user@host/channel
  identity. Clearly incompatible old/current hostmasks are rejected so a
  recycled nick cannot inherit somebody else's absence.
- Pending comeback candidates are capped at 200 and expire after 24 hours.
  Multiple channel JOINs preserve the first long-absence sample instead of
  replacing it with the freshly updated `USER_SEEN` timestamp.
- No new table, migration or configuration key is required.

### mb655 — activity streak achievements
- Added three user-facing streak milestones that reuse the existing `!streak`
  career calculation: **On a Roll** (7 consecutive active days), **Habit
  Formed** (30 days) and **Streak Master** (100 days).
- The milestones share the persistent `activity_streak_days` progress counter,
  so `!achievements progress` and next-goal rendering can show streak progress
  without a new table or schema change.
- `!streak` records the already-computed **best-ever** run rather than adding a
  second `CHANNEL_LOG` scan to the message hot path. Progress is monotonic: a
  later broken streak cannot erase past merit.
- Only checking one's **own** streak may update Achievement persistence. Looking
  up another nick remains read-only and cannot create/touch that person's
  durable Achievement profile as a side effect.
- Existing configurable achievement thresholds continue to apply through the
  generic `[achievements]` override mechanism; no new configuration key is
  required.

### mb654 — read-only achievement identity diagnostics
- Added `Mediabot::Achievements::identity_profile_diagnostic()` to explain the
  current durable per-channel profile, registered USER anchor, alias set, unlock
  count and progress-counter count without observing, touching, creating or
  merging an identity.
- The diagnostic queries MariaDB with `SELECT` statements only and deliberately
  avoids `_channel_id()`, `_profile_id_for()` and `observe_identity()` so an
  operator inspection cannot refresh caches or mutate persistence state.
- Nick-only ambiguity is reported rather than guessed: if multiple durable
  profiles match the requested nick on one channel, every candidate is shown
  and no profile is selected.
- Legacy JSON installations report the historical nick+channel key and merit
  counts but explicitly state that no durable alias graph exists.
- Added Partyline `.achievementprofile <nick> <#channel>` as a bounded, read-only
  rendering of those facts. Alias display is capped at 20 records.
- Historical merge reasons are not invented: mb646 never stored an audit trail,
  so the command distinguishes current durable evidence from unknowable past
  resolution decisions. No database schema change is required.

### mb653 — Trivia migrated to shared AsyncWorker
- `_trivia_fetch_async()` now delegates pipe/fork ownership, `watch_process`,
  bounded child transport, timeout escalation and callback-once finalisation to
  `Mediabot::AsyncWorker`; Trivia keeps only fetch policy, stage diagnostics and
  its established IRC-facing result vocabulary.
- The shared AsyncWorker protocol now supports bounded newline-delimited
  progress records before the one terminal result record. Existing consumers
  that do not need progress remain compatible and may ignore the emitter.
- Trivia preserves its existing operational limits: 24s default/30s capped
  outer timeout, 0.5s TERM grace, 1.5s liveness backstop, the synchronous
  no-event-loop compatibility path, and the historical 20 KiB per-result
  safety check inside the Trivia child.
- MB396 stage diagnostics survive the migration: `_trivia_fetch_sync()` streams
  safe progress metadata through `on_progress`, so timeout/failure reports still
  retain the last observed stage without logging remote question payloads.
- Shared worker terminal states are adapted back to the established Trivia
  error classes (`worker_timeout`, `worker_failed`, `worker_payload`,
  `worker_decode`, etc.) together with exit/signal/output/elapsed metadata.
- Tests 541/613/614 now verify delegation rather than requiring another private
  subprocess implementation in `UserCommands.pm`; test 833 extends the shared
  contract with ordered progress transport and test 835 covers the Trivia
  adapter, progress diagnostics, timeout translation and launcher failure.
- This remains an incremental migration: Achievements, CommandAsync and YouTube
  are deliberately untouched.

### mb652 — version checker migrated to shared AsyncWorker
- `getVersion_async()` is the first production consumer migrated to
  `Mediabot::AsyncWorker`; the version checker no longer owns its own
  pipe/fork, `watch_process`, stream, timers or TERM/KILL lifecycle.
- The shared worker now owns subprocess transport, bounded JSON envelopes,
  process completion and timeout escalation while `Mediabot::Helpers` keeps
  only version-specific policy: cached-local fallback, remote-version
  validation and operator-facing failure wording.
- The historical no-event-loop synchronous compatibility path is preserved for
  startup/tests and callers that cannot use IO::Async.
- Version-worker limits are preserved (`max_output=1024`, TERM grace 0.2s,
  liveness grace 2s), as are the established reasons for timeout, signal,
  non-zero exit, empty/invalid payload and worker setup failure.
- A `getVersion()` exception is still converted inside the child into a clean,
  bounded `version check crashed: ...` reason rather than becoming a silent
  `Undefined` remote version.
- Historical lifecycle tests 539/818/820–823 now verify delegation instead of
  requiring a private duplicate implementation in `Helpers.pm`; test 833 keeps
  the remaining consumers protected from an accidental big-bang migration.
- New test 834 exercises the version adapter contract, AsyncWorker argument
  wiring, child success/crash policy and terminal error translation. Trivia,
  Achievements, CommandAsync and YouTube remain untouched in this round.

### mb651 — shared AsyncWorker contract
- Added `Mediabot::AsyncWorker`, a consumer-neutral asynchronous subprocess
  contract built on an explicit pipe/fork pair with `IO::Async::watch_process`
  as the normal owner of child completion.
- The shared lifecycle centralises timeout handling, TERM→KILL escalation,
  a forced liveness backstop, bounded child output, JSON child→parent
  envelopes, exit/signal metadata and callback-once finalisation.
- Child exceptions and transport/setup failures become structured results
  instead of leaking dies into the event loop. Explicit cancellation uses the
  same bounded termination path.
- Child processes exit through `POSIX::_exit` and write only to their dedicated
  IPC descriptor. Consumer-specific inherited DB/socket safety remains the
  consumer's responsibility inside the child callback.
- The abstraction deliberately provides no implicit synchronous fallback:
  callers remain responsible for choosing whether a failed async setup may
  fall back, fail closed or retry.
- New test 833 exercises real fork/pipe transport against a deterministic
  event-loop harness: success, structured JSON, child exception, output bound,
  timeout with TERM/KILL, cancellation, setup failure and callback-once races.
- No existing worker consumer is migrated in this round; version, Trivia,
  Achievements, command workers and YouTube keep their current implementation
  until the shared contract is proven independently.

### mb650 — test-suite profiler
- `t/test_commands.pl` gains an opt-in `--profile` mode that measures each test
  file with `Time::HiRes` while preserving the existing execution order,
  assertion accounting and final exit status.
- `--profile-top N` limits the ranked report (default 20) and also enables
  profiling when used on its own. Invalid non-positive limits fail fast.
- The report is sorted slowest-first and records elapsed seconds, runner mode
  (`runner`, `isolated`, `load-error` or `skip`) and assertions contributed by
  each file, plus cumulative per-case time. A leading `!` marks files that
  contributed a failed assertion.
- Profiling includes case loading and execution; standalone TAP subprocess
  cases are timed around their complete isolated lifecycle, so the report
  reflects the cost paid by the real suite rather than only closure runtime.
- Profiling is deliberately observational: this round does not parallelise,
  reorder or skip tests. The measured data is intended to drive the later
  PURE/FILESYSTEM/PROCESS/DB/NETWORK classification before any concurrency is
  considered.
- New test 832 exercises opt-in behaviour, top-N ranking, sorting, preserved
  normal verdicts and invalid-limit handling.
- Profiler clock calls are fully qualified (`Time::HiRes::time`) instead of
  importing `time` into the shared runner namespace. This preserves the normal
  integer `CORE::time()` semantics of loaded test cases, including reminder
  `[at:TS]` parsing.

### mb649 — Mediabot Doctor, round 3 : database + migrations read-only
- Deuxieme passe de normalisation `information_schema` : MariaDB peut exposer
  `COLUMN_DEFAULT` sous forme de token SQL `NULL` ou de litteral deja quote
  (`'irc'`, `''`). Le checker ne transforme plus ces valeurs en faux
  `DEFAULT NULL` / `'''irc'''`; les differences de valeur reelles restent
  visibles.
- Revue terrain du schema drift : le checker ne confond plus les largeurs
  d affichage MariaDB (`BIGINT(20)`, `INT(11)`, etc.) avec des changements de
  type reels. Les charset/collations explicites restent verifies, `DEFAULT NULL`
  nullable et les commentaires de colonne sont canonicalises sans masquer un
  vrai ecart.
- Doctor ne classe plus automatiquement tout `RC=1` du drift checker en
  `UNSAFE` : une table/colonne/donnee de reference requise manquante reste FAIL,
  tandis qu un drift de type/index sans objet requis manquant est WARN/DEGRADED.
  Le checker reste la source de verite ; seule la severite operationnelle est
  contextualisee par Doctor.
- Les migrations avec effets manquants nomment maintenant les effets precis
  (table/colonne/index/contrainte/chanset) et rappellent explicitement que leur
  absence ne prouve pas que le fichier de migration n a jamais ete execute.
  L audit read-only DEV a notamment distingue des tables existantes de leurs
  foreign keys encore absentes au lieu de resumer cela a « migration manquante ».
- Nouveau test 831 pour la normalisation du schema MariaDB et extension du test
  830 pour la severite drift et les details d effets de migration.
- La sonde database reutilise le chemin non fatal
  `Mediabot::DB::connect_isolated_handle()` sans jamais appeler le constructeur
  `Mediabot::DB->new()` qui peut terminer le processus sur erreur. Les secrets
  restent confines a l objet de configuration lexical de la sonde et n entrent
  jamais dans le contexte partage ni dans le JSON de diagnostic.
- Avant toute requete Doctor, la connexion dediee impose
  `SET SESSION TRANSACTION READ ONLY`. Les seules lectures propres au Doctor
  sont des `SELECT`/`information_schema`; aucun DDL/DML de migration n est
  execute.
- Doctor rapporte la base active, le driver/version serveur, le charset/collation
  de session et l etat des quatre tables MB646. Quatre tables presentes =
  stockage MariaDB disponible, aucune = fallback JSON supporte mais WARN, et un
  schema MB646 partiel = FAIL.
- Le schema drift n est PAS reimplemente : Doctor invoque
  `tools/check_schema_drift.pl --strict --types --indexes --ignore-extra --quiet`
  avec un timeout borne. Le checker reste la source de verite pour le schema
  requis et les donnees de reference ; les objets live supplementaires ne sont
  pas assimiles a une rupture de compatibilite.
- La sonde migrations lit uniquement `install/migrations/*.sql` et en extrait
  des effets durables observables (tables, colonnes, index, contraintes et
  lignes `CHANSET_LIST`). Elle compare ces effets a la base en lecture seule et
  utilise exclusivement les etats `observable_effect_present`,
  `observable_effect_missing` ou `indeterminate`. L historique d execution n est
  jamais invente : aucun ledger de migrations n existe.
- Les formes SQL actuellement presentes dans les 18 migrations officielles sont
  couvertes, y compris les ALTER dynamiques de `QUOTES.hits`, l index compose de
  `CHANNEL_LOG`, les foreign keys conditionnelles et les migrations data-only de
  chansets. Une future mutation non modelisee devient `indeterminate` au lieu de
  produire un faux OK.
- Le message filesystem sur `achievements.json` devient neutre : l absence du
  JSON n est plus presentee comme preuve de stockage MariaDB ; c est la sonde
  database qui tranche desormais le mode de persistance.
- Nouveau test 830 pour la connexion non fatale/read-only, la delegation du
  schema drift, les trois etats MB646, les 18 signatures de migrations courantes
  et l interdiction de pretendre qu une migration a historiquement ete appliquee.

### mb648 — Mediabot Doctor, round 2 : systemd + updater/deploiement
- Doctor distingue maintenant trois verites systemd qui ne doivent jamais etre
  confondues : le gestionnaire reel observe dans `/proc/<pid>/cgroup`, le
  marqueur `MEDIABOT_SYSTEMD_UPDATE_SAFE=1` du processus, et le contrat de
  l'unite lu par `systemctl show`. Un marqueur qui pretend « safe » face a une
  unite non conforme devient un FAIL au lieu de masquer le probleme.
- Le contrat MB645 est verifie en lecture seule : `Restart=always`,
  `ExitType=cgroup`, ainsi que la politique d'exit 75
  (`SuccessExitStatus` + `RestartPreventExitStatus`). Aucun restart, daemon-reload
  ou changement systemd n'est effectue.
- La sonde updater reutilise `Mediabot::Update::protected_paths()` et
  `update_eligibility()` au lieu de recopier les regles chemin+hote. Une
  installation volontairement protegee ou un arbre non-`mediabot_v3` est INFO ;
  un updater reellement casse reste WARN.
- Etat Git strictement local : checkout/non-checkout, branche/HEAD, worktree sale
  et divergence par rapport a l'upstream deja en cache. Doctor ne fait aucun
  `fetch`, `ls-remote` ou acces reseau. Un deploiement non-Git est supporte.
- Les archives de deploiement sont groupees par basename EXACT du root courant
  (`<root>.NNN` et `<root>.old.YYYYMMDD_HHMMSS`) ; les familles soeurs sont
  comptees comme ignorees et ne peuvent pas entrer dans le resultat de la
  famille courante.
- Correction terrain du round 1 : `0660`/`0640` sur un groupe de service
  reellement prive n'est plus signale comme trop permissif. Doctor enumere les
  comptes ayant ce GID primaire et les membres supplementaires avant de conclure ;
  un groupe partage reste WARN.
- Les filtres `--domain` conservent maintenant les dependances de collecte :
  `systemd` et `filesystem` executent silencieusement la sonde runtime pour
  obtenir le PID et l'identite de service, sans afficher le domaine runtime si
  l'operateur ne l'a pas demande. Un diagnostic filtre ne peut donc plus changer
  la verite observee.
- Nouveau test 829 pour les contrats systemd/updater, l'isolation des familles
  de deploiement, l'absence de reseau Git et la semantique du groupe prive.
- Validation terrain Undernet : `mediabot.pl` est lance explicitement par
  `/usr/bin/perl`, donc l'absence de bit `+x` sur le script deploye n'empeche
  pas le runtime. Doctor distingue maintenant execution directe (sans `+x` =
  FAIL) et lancement via Perl (sans `+x` = WARN de packaging, runtime viable),
  au lieu de produire un faux FAIL filesystem.
- Correction de severite inter-domaines : le contrat MB645 n'est plus juge
  `UNSAFE` hors contexte. `systemd` collecte silencieusement l'applicabilite de
  l'updater ; un ancien contrat `Restart=on-failure`/`ExitType=main` sans
  marqueur reste INFO lorsqu'une installation utilise volontairement un autre
  mecanisme de deploiement (cas `mediabot3`), mais reste FAIL si l'updater
  integre est applicable. Un marqueur `MEDIABOT_SYSTEMD_UPDATE_SAFE=1` mensonger
  face a une unite non conforme reste toujours FAIL. `--domain updater` collecte
  aussi silencieusement runtime afin de juger les droits avec l'identite du bot.

### mb647 — Mediabot Doctor, round 1 : noyau, modele de faits, sondes locales
- Nouvel outil tools/mediabot_doctor.pl, STRICTEMENT en lecture : il n'ecrit
  rien, ne touche aucune base, n'envoie aucun signal au bot, et ne collecte
  jamais la valeur d'un secret. Perimetre de ce round : noyau + filesystem +
  config + runtime.
- ORCHESTRATEUR, PAS REIMPLEMENTEUR. Le depot contient deja
  check_schema_drift.pl (1077 lignes), startup_integrity_check.pl et
  security_audit.pl : Doctor les invoquera plutot que de refaire leur travail.
  Une seconde analyse de schema divergerait au premier ALTER TABLE.
- L'interface des SEPT sondes est figee des ce round : systemd, updater,
  database et migrations sont DECLARES (avec leur contrainte) mais pas
  implementes. Un domaine silencieux serait indiscernable d'un domaine sain ;
  ils rendent donc un fait « not_implemented » explicite.
- Modele de faits ferme (domain, id, level, summary, detail, SOURCE, data) :
  domaine/niveau/provenance invalides sont refuses au lieu d'etre normalises
  silencieusement. schema_version=1, rendus texte et --json depuis le meme
  modele, avec verdict global READY / DEGRADED / UNSAFE.
- Cinq niveaux dont UNKNOWN, qui n'est PAS une gravite mais l'aveu qu'un fait
  n'a pas pu etre etabli — jamais un OK par defaut, jamais un FAIL alarmiste.
  Regle ecrite apres mb640, ou un eval nu rendait panne reseau et bug de code
  indiscernables.
- SECRETS : leur valeur n'entre pas dans le modele, meme masquee. Masquer au
  rendu serait insuffisant puisque le JSON se recopie dans un ticket ou un
  canal ; on ne conserve que present=true/false.
- config : les clefs manquantes sont classees required / defaulted / optional
  — une clef absente n'est pas automatiquement un probleme. Les seules clefs
  DB fatales du constructeur actuel sont les vraies mysql.MAIN_PROG_DDBNAME
  et mysql.MAIN_PROG_DBUSER ; aucune clef de connexion fictive n'est inventee.
  Un arbre sans source analysable rend UNKNOWN au lieu de paraitre sain.
- runtime : un PID vivant n'est pas « le bot tourne » — Doctor confirme
  separement le mediabot.pl de CET arbre et le --conf de CETTE instance depuis
  /proc/<pid>/cmdline. Un PID recycle ou une conf differente sont donc visibles.
  L'identite attendue pour les droits filesystem est DERIVEE du processus.
- filesystem : verifie aussi les chemins structurants, le bit executable de
  mediabot.pl, les liens symboliques, les permissions de conf et, quand un
  processus est observe, les droits calcules pour SON uid/groupes plutot que
  ceux de l'utilisateur qui lance Doctor. achievements.json absent reste INFO
  en mode MariaDB ; le round database tranchera le fallback legacy.
- Une sonde qui plante devient un fait UNKNOWN et n'emporte pas
  l'orchestrateur : verifie par test, et constate en execution reelle des la
  premiere passe.
- NOTE POUR LE ROUND DATABASE : ne pas appeler Mediabot::DB->new(), ce
  constructeur peut exit(1) sur une conf invalide et tuerait l'outil.
- Test 828 couvre les REGLES et regressions CLI/runtime/filesystem, non la forme du code des sondes.

### mb645 — l'auto-update et systemd partagent enfin le meme cycle de vie
- TERRAIN (nbot) : la mise a jour clonait, validait, preservait la conf/le
  cerveau et activait correctement la nouvelle release, puis le bot restait
  arrete. Cause : `deploy_update.sh` envoie SIGTERM, Mediabot termine proprement
  (`exit 0`) et le template publie utilisait `Restart=on-failure`.
- DIAGNOSTIC SYSTEMD : l'echec initial de l'unite sur nbot n'etait PAS lie au
  template `bash -lc`/`stdbuf` : un ancien processus Mediabot possedait encore
  le verrou PID. Le template multi-instance eprouve sur teuk.org est donc
  conserve (`EnvironmentFile=/etc/default/mediabot-%i`, `BOT_DIR/BOT_BIN/BOT_CONF`).
- CONTRAT : le template passe a `Restart=always` + `ExitType=cgroup`.
  L'updater, fork/setsid depuis le bot, reste membre du cgroup de l'unite :
  systemd attend ainsi la fin de la restauration/rotation avant de redemarrer
  la nouvelle release. Aucune course ne depend plus des 10 secondes de
  `RestartSec`.
- COMPATIBILITE : `Restart=always` permet aussi a une release plus ancienne,
  dont le handler SIGTERM sort avec status 0, de revenir apres sa premiere
  auto-update vers le code courant.
- ARRET VOLONTAIRE : le nouveau template exporte
  `MEDIABOT_SYSTEMD_UPDATE_SAFE=1`. Avec ce marqueur, `die` et Partyline `.die`
  memorisent l'exit 75, declare a la fois dans `SuccessExitStatus=75` (arret
  volontaire = succes) et `RestartPreventExitStatus=75` (aucun restart). Sans le
  marqueur (ancien template `Restart=on-failure` ou lancement manuel), ils
  gardent l'exit historique 0 : une mise a jour du code seule ne transforme
  donc jamais `die` en restart involontaire.
- FAIL-CLOSED : `deploy_update.sh` identifie l'unite depuis le cgroup du PID
  cible et verifie `Restart=always` + `ExitType=cgroup` AVANT SIGTERM. Une
  ancienne/mauvaise unite fait echouer l'update sans couper le bot.
- DOCUMENTATION : `ExitType=cgroup` requiert systemd >= 250 pour le contrat
  d'auto-update. Le template public et la documentation systemd restent
  multi-instance et ne codent aucun chemin dev en dur.
- Nouveau test 825 : verrouille le template eprouve, le contrat systemd,
  l'ordre garde->SIGTERM, l'exit 75 de `die`/`.die` et la compatibilite
  SIGTERM des anciennes releases.

### mb644 — la frontiere IRC decode enfin le texte une seule fois
- DIAGNOSTIC TERRAIN : un probe sur `#teuk` a mesure le texte livre par
  Net::Async::IRC : `utf8_flag=0`, avec les vrais octets UTF-8 (`C3 A9` pour
  `é`, `C5 93` pour `œ`). Un second probe DB a montre l'autre cote de la
  frontiere : DBD::MariaDB 1.24 rend les colonnes texte comme chaines Perl
  Unicode (`utf8_flag=1`). Injecter directement les octets IRC dans DBI
  reproduit exactement le double encodage `é -> Ã©` (`C3 A9 -> C3 83 C2 A9`).
- FIX : `Mediabot::Helpers::decode_irc_text()` devient la frontiere unique
  fil IRC -> application. Un PRIVMSG UTF-8 valide est decode UNE fois juste
  apres extraction des hints ; une chaine deja Unicode reste inchangee et une
  entree legacy/invalide reste en octets, sans hypothese destructive.
- SECURITE DE REPRESENTATION : `Encode::LEAVE_SRC` empeche le decode strict de
  consommer/modifier sa source — le bug du probe temporaire qui avait vide
  `[LIVE]` ne peut donc pas se reproduire dans le helper. Les commandes privees
  portant des credentials (`login`, `pass`, `register`, `identify`, etc.)
  conservent volontairement leurs octets historiques afin de ne jamais changer
  la semantique d'un mot de passe existant.
- HAILO : les trois anciens `decode("UTF-8", $what, ...)` du handler principal
  disparaissent ; l'entree directe `mbHandleNickTriggered` reutilise le helper
  idempotent au lieu de tenter un second decode.
- DB : aucun attribut DBD::MariaDB exotique, aucun changement de schema, aucun
  changement de connexion. Le correctif agit avant les binds texte, la ou les
  representations divergent reellement.
- Nouveau test 824 : octets UTF-8 reels, chaine deja decodee, ASCII, octets
  invalides, non-mutation de la source, ordre de la frontiere dans PRIVMSG,
  disparition du probe et absence de double decode Hailo.

### mb643 — le worker de version adopte le pipe/fork eprouve en production
- TERRAIN (nbot/Epiknet) : mb642 supprimait le faux
  `version check worker could not be reaped`, mais `m update` pouvait ensuite
  rester suspendu sans reponse finale. Le test reel sur l'instance Epiknet a
  reproduit le hang.
- CAUSE : le worker utilisait encore le `open(..., '-|')` special de Perl tout
  en confiant le meme PID a `IO::Async::watch_process()`. Ce piped-open garde
  sa propre gestion de processus et ne constitue pas une base saine pour le
  watcher IO::Async.
- FIX : `getVersion_async` suit maintenant le pattern deja eprouve par le
  worker Achievements : `pipe()` explicite, `fork()` explicite, fermeture des
  extremites inutiles, ecriture du JSON sur le descripteur enfant et
  `watch_process()` comme proprietaire unique de la fin du processus.
- LIVENESS : apres le timeout, TERM puis KILL restent inchanges ; une garde de
  finalisation forcee a +2 s garantit qu'une notification de processus perdue
  ne peut plus laisser la commande IRC pendue indefiniment.
- VALIDATION TERRAIN : sur nbot/Epiknet, `m update` repond en ~1 s avec la
  version locale et la version GitHub identiques puis `Already up to date`.
- Nouveau test 823 : verrouille le pipe/fork explicite, l'absence de piped-open,
  le descripteur d'ecriture dedie, `watch_process()` et la garde de liveness.

### mb642 — le worker de version laisse IO::Async recolter son propre enfant
- TERRAIN (#teuk) : `m update` terminait en ~1 seconde avec
  `version check worker could not be reaped` alors que le fetch distant avait
  le temps de reussir. Ce n'etait pas un echec GitHub : le parent et IO::Async
  se disputaient le meme PID.
- CAUSE : `getVersion_async` pollait `waitpid(..., WNOHANG)` alors que la boucle
  IO::Async possede deja SIGCHLD et la collecte des processus. Le projet avait
  deja corrige exactement cette course dans le worker YouTube (MB321) avec
  `watch_process()`, mais le worker de version avait reintroduit l'ancien
  schema.
- FIX : le PID est desormais enregistre avec `watch_process()` ; le statut brut
  fourni par IO::Async alimente les diagnostics signal/exit. Tout `waitpid`
  manuel disparait de `getVersion_async`. Le timeout conserve TERM puis KILL,
  et la fin attend toujours a la fois le statut enfant et EOF (sauf timeout).
- Si la boucle ne sait pas surveiller les processus, ou si l'enregistrement du
  watcher echoue, le callback recoit une raison explicite sans bloquer l'IRC.
- Le diagnostic `version sources` ne pretend plus qu'un override est actif
  quand les URL GitHub integrees sont utilisees : il indique comment definir
  `update.VERSION_URL` pour les remplacer.
- Tests 539/821 adaptes ; nouveau test 822 verrouille la propriete SIGCHLD par
  IO::Async, l'absence de `waitpid` manuel et le libelle source non trompeur.

### mb641 — derniere garde : aucun chemin terminal du worker ne reste muet
- AUDIT pre-commit de mb640 : la promesse « ne jamais echouer en silence »
  restait fausse sur quatre chemins rares mais reels. Un echec de `open(...,
  '-|')` appelait encore le callback sans raison ; un `waitpid` impossible, un
  enfant termine par signal/exit non-zero et un payload JSON tronque mais non
  vide pouvaient eux aussi rendre `github: Undefined` sans explication.
- Chaque terminaison a maintenant sa raison propre, monoligne et bornee :
  worker impossible a lancer, impossible a reap, signal, code de sortie,
  resultat vide ou resultat invalide. Le timeout garde son message specifique.
- Le fallback local est normalise comme les autres chemins (`Undefined` plutot
  qu'un undef Perl brut). Aucun comportement nominal ni politique HTTP/TLS ne
  change.
- Nouveau test 821 : verrouille toutes les sorties terminales et interdit le
  vieux callback a deux arguments sur l'echec de creation du worker.

### mb640 — le check de version cesse d'echouer en silence (deux bugs a moi)
- TERRAIN (#teuk, deux fois) : « local: 3.4dev-... | github: Undefined » puis
  « Cannot check: version could not be determined », sans la moindre raison,
  alors que mb638/mb639 etaient censes en fournir une. Deux defauts, tous
  deux introduits par moi.
- (A) mb637 forgeait un client HTTP a part avec « verify_SSL => 1 ». Or tout
  le bot passe par Mediabot::External::_make_http, dont le commentaire dit
  exactement pourquoi : « verify_SSL defaults to 0 for OVH/Kimsufi
  compatibility ». Le serveur cible EST un Kimsufi/OVH : la verification
  echouait instantanement — d'ou une reponse en UNE seconde la ou un blocage
  reseau aurait consomme tout le delai. Le fetch reutilise desormais le
  client commun : une seule politique TLS pour tout le bot.
- (B) Plus grave : une EXCEPTION de getVersion etait avalee par un eval nu.
  Le fils n'ecrivait alors rien, le parent retombait sur le local EN CACHE, et
  aucune raison n'existait — bon local, « Undefined », zero explication : la
  capture, mot pour mot. Une panne reseau et un plantage du code produisaient
  le meme ecran. L'exception devient une raison (« version check crashed:
  ... »), sur le chemin fork COMME sur le chemin sans event loop, nettoyee du
  « at ... line N » et bornee a 200 caracteres.
- Un fils muet (payload vide ou illisible) produit lui aussi sa raison, sans
  jamais ecraser une raison deja connue.
- BUGS DE TEST PREEXISTANTS corriges au passage : la suite livree arrivait
  ROUGE (12796/12798). Deux assertions de la passe mb639 etaient fausses —
  « scalar(liste) » rend le DERNIER ELEMENT et non le compte, et le cas
  « URL invalide => deux sources essayees » reutilisait une reponse en SUCCES,
  qui arrete legitimement la boucle a la premiere URL. Le code etait juste,
  les attentes ne l'etaient pas.
- Pins 138 et 207 suivent le client commun. Test 820 (21 assertions) : usage
  du client partage, absence de tout client forge a part, exception -> raison
  sur les deux chemins, message propre et borne, fils muet, et chemin nominal
  qui n'invente aucune alarme.

### mb639 — garde pre-commit : le diagnostic distant tient ses propres promesses
- AUDIT de mb638 : `update.VERSION_URL` etait documente comme un override qui
  force UNE URL, mais le code la placait seulement devant les deux URL GitHub.
  Une URL explicite remplace desormais la liste par defaut ; une valeur invalide
  est ignoree et conserve les deux URL integrees.
- `VERSION_TIMEOUT` est maintenant un delai PAR URL et le timeout du worker
  asynchrone est calcule pour laisser a toutes les URL selectionnees le temps
  d'etre essayees. Le `timeout => 8` fixe de `update_ctx` annulait sinon le fils
  au moment ou la premiere URL lente expirait, avant le miroir.
- Le support SSL n'est exige que si la liste choisie contient HTTPS : un
  `VERSION_URL=http://...` explicite reste utilisable sur un reseau de confiance.
- Un HTTP 200 n'est accepte que si le corps est une vraie version Mediabot
  comprise par `_version_parts`. Une courte page HTML sur une seule ligne ou
  un texte de proxy ne peut donc plus passer pour une version.
- `getVersion` efface son ancienne raison d'echec avant chaque tentative :
  une erreur reseau precedente ne peut pas etre recyclee si, au check suivant,
  c'est la version locale qui devient illisible.
- Test 818 renomme mb638 et etendu de 23 a 33 assertions ; nouveau test 819
  (12 assertions) pour le budget worker, l'override URL reel et l'absence de
  raison stale.

### mb638 — « update » dit POURQUOI la version distante manque
- TERRAIN (#teuk) : « local: 3.4dev-... | github: Undefined » puis « Cannot
  check: version could not be determined » — aucune prise pour l'operateur.
- CAUSE, et c'est un defaut de conception de mb631 : la commande s'appuie sur
  getVersion_async, dont le FILS tourne avec un logger volontairement muet
  (_SilentLogger, pour ne pas doubler les traces de demarrage). getVersion
  journalisait bien « Failed to fetch version from GitHub: HTTP 599 », mais
  dans le fils cette ligne partait au neant. Une panne reseau et une absence
  de version devenaient donc indiscernables — et le diagnostic impossible a
  distance.
- Le fetch distant devient une fonction unique, Helpers::fetch_remote_version,
  qui rend (version, RAISON). getVersion la consomme — plus de seconde
  implementation de la requete. La raison traverse le tuyau enfant -> parent
  (3e valeur du payload JSON) et arrive au callback en 3e argument ; les
  appelants historiques qui n'en veulent pas l'ignorent.
- Chaque mode de panne a desormais sa phrase : HTTPS indisponible (« install
  IO::Socket::SSL and Net::SSLeay » — HTTP::Tiny ne fait pas d'https sans
  eux), HTTP <statut> avec le detail reseau que HTTP::Tiny place dans le corps
  d'un 599, fichier vide, contenu qui n'est pas un fichier VERSION (une page
  de proxy ou de portail captif n'est JAMAIS prise pour une version), et
  depassement de delai.
- Deux URL sont essayees — raw.githubusercontent.com puis le miroir
  github.com/<repo>/raw/<branche> — parce qu'un pare-feu, un proxy ou une
  route IPv6 morte peut n'en bloquer qu'une. La conf peut en imposer une
  (update.VERSION_URL) et regler le delai (update.VERSION_TIMEOUT).
- La commande affiche la raison ET le point de lecture, avec le moyen de le
  changer. Quand aucune raison n'est connue, le message generique subsiste.
- Pins 138 et 207 evolues : ils verrouillaient la requete DANS getVersion ;
  ils verrouillent desormais les memes garanties (aucune sortie shell, appel
  reseau sous eval, exception conservee) la ou elles s'appliquent.
- Test 818 (23 assertions) : chaque mode de panne avec sa raison, les deux URL
  essayees, l'URL de conf prioritaire et une URL invalide ignoree, le BOM, la
  traversee du tuyau, l'affichage par la commande, et le chemin nominal intact.

### mb637 — l'identite du canal source est canonique, pas celle tapee
- AUDIT pre-commit de mb636 : la cible explicite etait verifiee via la cle
  `lc(...)` du cache des canaux, mais la graphie fournie par l'operateur
  continuait ensuite dans SQL, les chansets et surtout la cle memoire
  `summary_last:<canal>`. `#35+ANS` puis `#35+ans summary last` pouvaient donc
  creer deux timelines pour le meme canal IRC.
- Apres reconnaissance, la branche recupere desormais le nom canonique via
  l'objet `Channel->get_name` et n'utilise plus que cette identite stable pour
  les lectures, la langue, les annonces et l'horodatage `last`.
- Le test 817 utilise maintenant de vrais petits objets Channel et couvre une
  cible saisie avec une casse differente : bind SQL et annonce retombent tous
  deux sur `#35+ans`. 34 assertions au total dans le test cible.

### mb636 — « ai [#canal] summary » : resumer un autre canal depuis une console
- Nouvelle forme : « ai #35+ans summary » lit l'historique du canal NOMME au
  lieu du canal courant. Le jeton se place avant le mot summary et n'est
  reconnu QUE la — sans quoi « ai #linux c'est quoi ? » perdrait son premier
  mot au lieu de partir en question au modele.
- DEUX canaux desormais distincts, et tenus separes dans tout le corps de la
  sous-commande : $src_channel (celui qu'on LIT : requetes, comptage,
  horodatage du dernier resume, langue, libelle de l'annonce) et $channel
  (celui ou l'on PARLE : destination de « public »). Sans cible, les deux
  valent le canal courant — comportement historique strictement inchange.
- NIVEAUX. Administrator+ pour resumer, comme avant. Master+ EN PLUS pour
  publier le resume d'un AUTRE canal sur le canal courant : lire ailleurs
  pour soi et le recracher devant une audience qui n'etait pas dans la
  conversation sont deux gestes de nature differente — les gens du canal
  resume n'ont pas choisi ce public. La porte ne se leve que pour ce cas, et
  un refus n'execute AUCUNE requete.
- Un canal que le bot ne connait pas est annonce comme tel au lieu de rendre
  « aucun message trouve », qui laissait croire a un salon vide.
- La langue suit le canal RESUME (c'est sa conversation) ; un jeton force
  gagne toujours.
- Syntaxe canonique reecrite : le canal, la destination et les deux niveaux y
  figurent, avec les exemples demandes. Pins 630/791/806/813 alignes.
- Test 817 (31 assertions) : les quatre formes historiques inchangees, la
  cible explicite en notice, le croisement public refuse a un Administrateur
  SANS toucher la base puis accorde a un Master, le canal inconnu, la
  non-capture d'un prompt, et la separation source/destination verifiee sur
  chaque site de lecture.

### mb635 — l'updater prepare le nouveau chateau avant d'eteindre l'ancien
- AUDIT pre-commit : `deploy_update.sh` arretait le bot AVANT `git clone` et
  les validations du candidat. Un echec reseau ou un clone invalide creait
  donc une coupure inutile ; sous systemd, le restart pouvait aussi partir
  pendant que l'ancien arbre etait encore le chemin actif.
- L'ordre devient : clone -> syntaxe/integrity du STAGE -> SIGTERM -> copie de
  la conf et du dernier cerveau Hailo -> deux `mv` locaux -> validation finale.
  La partie lente et faillible se fait bot vivant ; la section critique apres
  SIGTERM est reduite au strict minimum.
- La conf et le cerveau restent copies APRES l'arret : le `.brn` sauvegarde est
  donc bien l'etat final du bot, pas une image prise pendant qu'il ecrit encore.
- Test 816 : verrouille l'ordre des etapes, la validation avant SIGTERM et la
  restauration de l'etat prive entre SIGTERM et activation.

### mb634 — la garde teuk.org exige le nom d'hote ENTIER
- CORRECTION demandee avant commit : `teuk.org` dans le NOM d'un autre hote
  ne suffit jamais a refuser une mise a jour. La protection integree ne
  s'applique que si le chemin normalise est `/home/mediabot/mediabot_v3` ET si
  le hostname courant est exactement `teuk.org` (casse ignoree, point DNS
  final optionnel).
- `mediabot.teuk.org`, `foo-teuk.org`, `teuk.org.example`, un autre serveur et
  un hostname introuvable sont donc autorises par CETTE protection integree.
  Les protections de conf `<path>@<host>` suivent la meme egalite exacte ;
  un `<path>` nu reste volontairement protege sur tous les hotes.
- `install/deploy_update.sh` applique la meme paire exacte chemin+hote et ne
  depend plus du compte Unix qui l'a lancee : root ne contourne pas la garde
  sur l'hote exact, et un sous-domaine n'est pas pris pour `teuk.org`.
- NUMEROTATION : la nouvelle commande update, appelee mb631 dans le CR Claude,
  devient mb632 car mb631 est deja le round `ai summary` commite. La passe
  chemin+hote devient mb633. Le test 814 est renomme en consequence et etendu
  pour verrouiller les faux positifs de sous-chaine et la garde shell.

### mb633 — la protection de l'update est un couple chemin+hote, pas un chemin
- CORRECTION d'une vraie erreur de mb632, relevee par teuk : proteger
  /home/mediabot/mediabot_v3 « quel que soit l'hote » etait faux. C'est le
  chemin d'installation NORMAL d'un mediabot — les autres serveurs
  (nbot.soyou.rocks entre autres) l'utilisent aussi. La commande aurait donc
  refuse la mise a jour precisement la ou elle est attendue, et n'aurait
  jamais pu etre essayee ailleurs qu'en la modifiant.
- La protection integree devient un COUPLE : /home/mediabot/mediabot_v3 SUR
  teuk.org, comme le fait deja install/deploy_update.sh. Le meme chemin sur
  un autre serveur redevient une installation ordinaire, donc updatable.
- L'hote courant est cherche a plusieurs sources (Sys::Hostname, POSIX::uname,
  /etc/hostname) parce qu'une seule peut rendre le nom court ; la
  correspondance est une sous-chaine insensible a la casse, comme le
  grep -qi "teuk\.org" du script — « teuk.org » attrape donc aussi
  « mediabot.teuk.org ».
- Hote INTROUVABLE sur un chemin protege : refus. Ne pas savoir ou l'on est
  n'est pas une raison de se croire ailleurs, et le cout d'un faux refus est
  un « fais-le a la main » la ou un faux accord ecraserait une production.
- Conf : update.PROTECTED_PATHS accepte desormais <chemin>@<hote> pour viser
  une instance, ou un <chemin> nu pour proteger partout (choix explicite de
  l'operateur). Elle ne peut toujours qu'AJOUTER.
- Test 814 etendu : matrice chemin×hote (prod refusee sous FQDN complet ou
  exact, MEME CHEMIN sur un autre serveur autorise, dev sur teuk.org
  autorise, slash final), refus prudent quand l'hote est inconnu, et les deux
  formes de conf.

### mb632 — `update` : mettre a jour Mediabot depuis GitHub, depuis IRC
- « m update » (reponse sur le canal) et « /msg mediabot update » (reponse en
  prive) interrogent GitHub, comparent avec la version locale et, avec
  « update now », installent la nouvelle version. Master+ requis.
- Nouveau module Mediabot/Update.pm. Il est ecrit a l'envers des autres : tout
  ce qui REFUSE d'abord, ce qui agit ensuite. Les regles de refus sont des
  fonctions PURES (update_eligibility, update_decision, restart_mode) parce
  que c'est la seule partie qu'une suite de tests peut prouver — l'echange
  reel (clone, bascule, SIGTERM) ne se rejoue pas.
- INSTANCE PROTEGEE : /home/mediabot/mediabot_v3 est refuse quels que soient
  l'utilisateur et la machine. La regle porte sur le CHEMIN, pas sur un
  triplet utilisateur+hote+chemin : « je suis root » n'ouvre pas la porte.
  La conf (update.PROTECTED_PATHS) ne peut qu'AJOUTER des chemins proteges,
  jamais en retirer — une protection desactivable n'est pas une protection.
- Prerequis verifies avant tout appel reseau : nom du repertoire, presence de
  mediabot.pl et de install/deploy_update.sh, bit executable, repertoire
  parent inscriptible (sans quoi la rotation des releases echouerait a
  mi-chemin).
- VERSIONS : le comparateur existant (_compare_mediabot_versions) et le
  fetch non bloquant existant (getVersion_async) sont reutilises — aucune
  seconde implementation. Cinq etats distincts : disponible, deja a jour,
  LOCAL EN AVANCE (refus de downgrade), illisible, incomparable. Seul
  « disponible » autorise l'action.
- Le travail lourd reste dans install/deploy_update.sh (clone, restauration
  de mediabot.conf et du cerveau Hailo, perl -c et integrity check sur
  l'arbre STAGE, rotation mediabot_v3 -> mediabot_v3.N, rollback si la
  validation post-bascule echoue).
- LE POINT QUE PERSONNE N'AVAIT NOMME : deploy_update.sh envoie SIGTERM au bot
  et NE LE REDEMARRE PAS. Sous systemd l'unite le relance ; lance a la main,
  le bot reste ETEINT. La commande detecte le mode et l'ANNONCE avant d'agir
  (« the bot will STAY DOWN until you start it again ») au lieu de laisser
  l'operateur le decouvrir.
- « update » seul ne fait QUE diagnostiquer ; seul « now » agit. Une commande
  qui remplace le code du bot ne se declenche pas sur un mot isole.
- Le script est lance DETACHE (setsid + double fork, sortie journalisee dans
  var/update.log) : il va tuer le bot, il ne peut donc pas rester son fils.
- install/deploy_update.sh : son message de refus renvoyait vers « la commande
  IRC » — laquelle refuse desormais exactement le meme chemin. Les deux portes
  disent la meme chose au lieu de se renvoyer l'une a l'autre.
- Test 814 (74 assertions) : chemin protege sous ses variantes, conf qui ne
  desarme rien, chaque prerequis manquant avec sa raison, les cinq etats de
  version, Master pose AVANT toute autre chose (un refus n'interroge pas
  GitHub et ne lance rien), diagnostic sans action, detection et annonce du
  mode de redemarrage, detachement, et coherence des deux portes.

### mb631 — 'ai summary' passe Administrator, et une garde de test cesse de mentir
- NUMEROTATION : cette passe etait nommee mb630 dans le CR Claude, mais mb630
  est deja le garde de verite du dispatch commite la veille. Elle devient donc
  mb631 ; le numero de test 813, lui, etait libre et reste 813.
- ACCES : la sous-commande summary exige desormais Administrator, sous
  TOUTES ses formes — en canal et en prive (les deux passent par claude_ctx)
  et en partyline. Le resume lit l'historique complet d'un salon et le fait
  ressortir reformule : c'est une capacite de moderation.
- La porte est le PREMIER traitement specifique de la branche, avant tout
  parsing/consommation des arguments et avant « help » : la sous-commande ne
  se documente pas a qui n'y a pas droit, et un refus n'atteint jamais la
  lecture CHANNEL_LOG du summary (la resolution d'identite reste normale).
- La partyline utilise son echelle INVERSEE (Owner=0, Master=1,
  Administrator=2, donc « level <= 2 »), documentee sur place pour qu'on ne
  la lise pas a l'envers plus tard. Les trois aides annoncent le niveau.
- Les autres sous-commandes de !ai (forget, models, stats, reset, history,
  pin) restent libres : le test le verifie explicitement.
- BUG DE TEST CORRIGE, trouve en verifiant la baseline : la suite arrivait
  ROUGE. La garde anti-mojibake du test 804 refusait « â » SEUL — or c'est
  une lettre francaise parfaitement legitime, et « âmes », « bâtis »,
  « tâche » vivent dans les pools de l'horoscope. Le tirage dependant de la
  DATE, la suite virait au rouge certains jours et au vert d'autres, pour
  une sortie strictement correcte. La garde vise desormais la vraie
  signature du double encodage — « Ã » suivi d'un caractere de continuation,
  « â€ », « Â » colle a une ponctuation — et deux assertions neuves prouvent
  qu'elle mord toujours sur un double encodage reel tout en laissant passer
  les circonflexes.
- Test 813 renforce : la porte partyline est aussi exercee au runtime et les
  autres sous-commandes doivent etre trouvees explicitement avant de verifier
  qu'elles restent libres (aucun `next` silencieux si le source evolue). Pins
  630 et 791 mis a jour (ligne d'aide), et le contexte simule du test 809 gagne
  require_level.

### mb630 — derniere garde : le test de dispatch cesse de mentir
- Le vieux test standalone 383 avait un piege Perl subtil : un `m//` rate
  passe en premier argument de `ok()` etait evalue en contexte de liste. La
  liste vide faisait glisser le libelle en premier argument, donc un contrat
  de dispatch casse s'affichait `ok - unnamed test` au lieu d'echouer.
- Toutes ses assertions regexp forcent desormais le contexte scalaire. Les
  routes `top`, `leaderboard/lb` et `chronos` acceptent leur enveloppe async
  moderne tout en exigeant toujours le bon handler final.
- `_irc_bytes` declare directement sa dependance `Encode` au lieu de compter
  sur le chargement transitif par Helpers ; le commentaire de mise en forme
  est corrige de mb628 vers mb629. Aucun comportement IRC n'est change.

### mb629 — le palmares passe Administrateur, et cesse d'etre un mur
- ACCES : leaderboard et son alias lb exigent desormais le niveau
  Administrator. La porte est posee AVANT le fork — un refus ne doit pas
  couter un worker — et le refus part du parent, comme pour toute commande
  de niveau. Les deux entrees d'aide l'annoncent.
- MISE EN PAGE : le defaut devient COMPACT. Les categories sont groupees par
  ligne (deux lignes au lieu de cinq d'affilee) ; « full » rend l'ancienne
  forme, une ligne par categorie, et « compact » revient au defaut. Le
  remplissage compte les OCTETS et non les caracteres : un emoji pese 4
  octets pour une seule case a l'ecran, et une ligne coupee par le serveur
  casserait une sequence de couleur en deux.
- COULEUR : une teinte par categorie (msgs, karma, trivia, duels, achievs),
  choisies lisibles sur fond clair COMME sur fond sombre — ni blanc ni noir —
  toutes distinctes, chaque sequence refermee juste apres son libelle. Le
  premier de chaque podium garde sa medaille et le gras ; les suivants
  restent sobres, sinon la ligne devient illisible a force de decorations.
- dashboard : couleurs ajoutees, contenu STRICTEMENT inchange — memes mots,
  meme ordre, memes valeurs (demande explicite : « pas de regression, c'est
  pas mal tel que c'est »). Le test verrouille chacune de ses six lignes.
- Bug attrape par le test : _irc_bytes se fiait au drapeau utf8, or un
  caractere < 256 (le point median, un « e accent ») peut etre stocke sans
  drapeau et pese pourtant 2 octets sur le fil — la mesure se declenche
  desormais des qu'il y a du non-ASCII.
- Bug attrape par le rendu reel : le separateur ecrit ' \x{B7} ' entre
  APOSTROPHES s'imprimait tel quel sur le canal ; c'est le caractere litteral
  qui est utilise, ce fichier declarant « use utf8 ».
- Pin 769 evolue : il exigeait que run_ctx_async soit le PREMIER mot du bloc
  de dispatch. Le contrat reel est « cette commande s'execute dans un
  worker » — il tolere maintenant une porte de niveau devant, et exige
  toujours le worker.
- Test 812 (35 assertions) : porte sur les deux alias et avant le fork,
  compact par defaut avec full/compact, mesure en octets (ASCII 1, emoji 4,
  point median 2, undef sans mort), simulation du compactage sur cinq
  categories (moins de cinq lignes, jamais une seule interminable, aucune
  couleur laissee ouverte en fin de ligne), unicite et lisibilite des
  teintes, separateur litteral, et les six lignes du dashboard conservees.

### mb628 — derniere garde : les tests disent la meme chose que le runtime
- Le test historique 709 attendait encore l'ancienne forme fonctionnelle dans
  le top-talker `onthisday`, alors que mb627 vient de la remplacer par une
  plage indexable. Il est aligne sur le nouveau contrat et verrouille les binds.
- `ai summary last` conserve sa borne historique stricte `ts > dernier_resume`.
- Si le comptage exact de mb626 echoue, la commande echoue fermee avec
  `DB error` au lieu de retomber sur une lecture tronquee.
- Le test 809 couvre les deux chemins runtime ; le test 811 verrouille la
  coherence runtime/tests et l'unicite des numeros recents.

### mb627 — les predicats de date redeviennent utilisables par l'index
- CLASSE DE DEFAUT : une fonction appliquee a la COLONNE dans un WHERE
  (DATE(ts), YEAR(ts), MONTH(ts)) interdit a MariaDB d'utiliser l'index
  (id_channel, ts) — la requete balaie. Sur une table a plus de 10 millions
  de lignes, c'est un balayage complet a chaque appel de la commande. mb577
  avait converti six sites et mb625 deux autres ; TROIS subsistaient, dont un
  oubli evident : la branche « mois courant » se trouve juste sous
  today/yesterday, deja convertis.
- Fenetre 365 jours : DATE(cl.ts) >= D devient cl.ts >= D. Equivalence exacte
  — DATE() tronque vers le bas, donc les deux formes selectionnent la meme
  journee de depart ; seule la fonction autour de la colonne disparait.
- Mois courant : YEAR+MONTH deviennent la plage [1er du mois, 1er du mois
  suivant), alignant la branche sur ses deux voisines.
- onthisday : dans les DEUX requetes par annee, YEAR(ts)=? AND MONTH(ts)=?
  AND DAY(ts)=? designe UNE journee precise, donc la plage
  [jour, lendemain). Un 29 fevrier inexistant rend NULL des deux cotes :
  aucune ligne, exactement comme avant.
- La requete qui cherche le meme jour SUR TOUTES les annees ne peut
  mathematiquement pas devenir une plage (et son GROUP BY YEAR(ts) l'impose
  de toute facon) : elle garde sa forme et porte desormais l'explication sur
  place, pour qu'un futur passage ne la « corrige » pas a tort.
- Test 810 (22 assertions) : recensement de la classe entiere (zero predicat
  non indexable hors du cas impossible, dont les definitions ne servent plus
  qu'a lui), forme de chaque conversion, conservation des branches voisines,
  perimetre inchange (longueur des citations, type d'evenement, podium), et
  surtout ARITE DES BINDS — l'expression de journee apparait DEUX fois dans
  la plage, donc les valeurs sont fournies deux fois, dans les deux modes
  (date explicite ou date du jour). C'est exactement la ou ce genre de
  conversion casse en silence.

### mb626 — une periode est lue sur toute sa largeur, et le total est le vrai
- Le defaut signale par teuk en mb623 subsistait A UNE AUTRE ECHELLE : la
  lecture d'une periode restait « ORDER BY id DESC LIMIT 1500 ». Sur une
  journee a 4000 messages, « ai summary today » lisait donc les 1500
  DERNIERS, puis echantillonnait « de maniere repartie »... sur cette fin
  seulement. Le bot annoncait « 1500+ » : il avouait un plafond, mais
  revendiquait une couverture qu'il n'avait pas. Corriger 200 en 1500 n'avait
  fait que deplacer le seuil du mensonge.
- Les bornes de periode deviennent explicites (_summary_period_bounds) et,
  au-dela du plafond, la fenetre est decoupee en 8 TRANCHES EGALES DANS LE
  TEMPS dont chacune fournit sa part : la couverture est reelle, du premier
  message de la journee au dernier. Les bornes intermediaires sont calculees
  par MariaDB (TIMESTAMPADD/TIMESTAMPDIFF), donc aucune date ne remonte dans
  Perl et chaque tranche reste une plage indexee sur (id_channel, ts).
- Sous le plafond, RIEN ne change : une seule requete, comme avant.
- Un comptage prealable (indexe, et portant le meme filtre pseudo que la
  lecture) donne le total EXACT : l'annonce dit desormais « 4213 messages sur
  la periode - resume sur un echantillon reparti de 400 » la ou elle disait
  « 1500+ ». Le « + » signalait un plafond sans dire sur quoi il portait.
- Test 809 (20 assertions) : bornes de chaque periode, arithmetique des
  tranches (extremites exactes, bornes intermediaires deleguees a la base),
  et surtout EXECUTION REELLE de la sous-commande contre une base simulee —
  une seule lecture sous le plafond, un comptage plus une lecture PAR TRANCHE
  au-dessus, chaque requete bornee dans le temps, total exact annonce, et
  filtre pseudo present jusque dans le comptage.

### mb625 — pre-commit truthfulness for the summary parsers
- The new AI-summary/recap rounds are renumbered to **mb623/mb624** (tests
  **806/807**) because mb618/mb619 and tests 801/802 already belong to the
  committed news arc. The changelog and test filters therefore remain unique.
- `ai summary <N>h` now has a localized period label in EN/FR/ES service
  messages; the new hours window was parsed and queried correctly but its
  human-facing label had been forgotten.
- The documented bounds are now actually strict: `<N>d` must be 1-30, `<N>h`
  1-72, bare message counts 5-50 and `<N>l` 1-10. Invalid values are reported
  instead of being silently clamped. A bare message count combined with a
  period is rejected instead of being accepted and ignored; duplicate count,
  line, language and nick selectors are also refused.
- The sampling notice renders the safety-cap marker as `1500+ messages` rather
  than the misleading `messages on the period+` form.
- `today` / `yesterday` use timestamp ranges instead of `DATE(cl.ts)`, keeping
  the `(id_channel, ts)` index usable when a period summary reads a busy log.
- `recap lang=de` now fails closed even without `ai`; strict syntax no longer
  accepts an invalid language only because the statistical path would ignore it.
- Test 808 locks numbering uniqueness, strict ranges, hour labels, capped
  wording, index-friendly date predicates and recap invalid-language handling.

### mb624 — recap herite des exigences de 'ai summary', et un seul detecteur
- La maladie corrigee dans 'ai summary' (mb623) vivait aussi dans sa commande
  soeur : recap IGNORAIT EN SILENCE tout jeton non reconnu. « recap 2h ia »
  — une faute de frappe sur 'ai' — rendait les statistiques au lieu du resume
  demande, sans un mot ; « recap 30min » retombait sur la fenetre par defaut
  sans le dire. Le bot repondait quelque chose de PLAUSIBLE, donc l'erreur
  etait invisible : c'est le pire cas.
- recap lit desormais ses arguments dans n'importe quel ordre, annonce les
  fautes de frappe avec la bonne forme (« ia » -> « ai », « 30min » -> « 30m »,
  « 2hours » -> « 2h ») et refuse les jetons inconnus comme les doublons
  (deux fenetres) au lieu de les avaler.
- Une faute de frappe n'active JAMAIS l'option devinee : signaler et s'arreter
  vaut mieux que decider a la place de l'utilisateur.
- La distance d'edition passe dans Helpers (edit_distance_1 / suggest_keyword) :
  UNE implementation pour tout le bot. La copie de Claude.pm disparait — deux
  copies auraient diverge au premier ajustement — et Claude declare desormais
  sa dependance au lieu de la supposer chargee.
- La langue de recap reste extraite par l'API PARTAGEE de mb609 : recopier sa
  regle dans le nouveau parseur aurait recree exactement la divergence que
  mb609 avait supprimee (rappele par le test 792, a juste titre).
- Syntaxe de recap ecrite UNE fois (@RECAP_USAGE_LINES), lue par l'aide comme
  par les messages d'erreur.
- Verification faite au passage : plus AUCUN module depourvu de « use utf8 »
  n'emet de litteral non-ASCII — la classe de bugs d'encodage des deux
  derniers rounds est entierement fermee.
- Test 807 (52 assertions), pin 792 aligne sur la source unique de syntaxe.

### mb623 — 'ai summary' : syntaxe claire, fautes annoncees, periode couverte
- TROIS DEFAUTS DE TERRAIN, corriges. (1) Une faute de frappe ne disait
  RIEN : « ai summary todya » survivait au filtre d'options et devenait le
  filtre PSEUDO — d'ou un « aucun message trouve » qui ressemblait a un canal
  vide. (2) « ai summary today » n'etait pas la journee mais
  « ORDER BY id DESC LIMIT 200 » : les 200 DERNIERS messages, en silence — sur
  un canal actif, on croyait resumer la journee en resumant la derniere demi-
  heure. (3) L'ordre des mots etait fige, la periode devait etre en premiere
  position.
- Le parseur devient une FONCTION PURE (_summary_parse) : ordre libre, chaque
  jeton classe, et ce qui n'entre dans aucune case est une ERREUR annoncee.
  Le test l'interroge directement au lieu d'extraire du source par regex.
- Fautes de frappe : « todya », « yesteday », « wek », « lat », « publi » sont
  detectes par distance d'edition 1 sur les mots-cles et SUGGERES, avec le
  rappel de nick=<pseudo> pour le cas ou ce serait vraiment un pseudo. Aucun
  vrai pseudo n'est requalifie en erreur (verifie sur teuk, SaYa, Te[u]K...).
  Jetons illisibles et doublons (deux periodes, deux pseudos) : refus explicite.
- Une periode lit desormais jusqu'a 1500 messages, et si c'est trop pour un
  prompt, l'echantillon est REPARTI (debut, milieu, fin, la fin plus dense)
  au lieu de garder la seule fin. Le compte reel est annonce : « 1842 messages
  sur la periode - resume sur un echantillon reparti de 400. » Un resume qui
  ne couvre pas tout le dit.
- Nouvelle fenetre <N>h (1-72 heures) : « ce qui s'est dit depuis mon
  dejeuner » etait impossible a demander — today trop large, un compte de
  messages trop aveugle.
- La syntaxe est ecrite UNE fois (@_summary_usage_lines) et lue par l'aide
  comme par les messages d'erreur : elles ne peuvent plus diverger.
- Pins 630 et 791 evolues : ils verrouillaient la FORME de l'ancienne passe
  grep et l'ancienne ligne d'aide ; ils verrouillent desormais le
  COMPORTEMENT du parseur et la liste de syntaxe. Test 806 (47 assertions).

### mb622 — l'alias horo suit le meme chemin asynchrone que horoscope
- Depuis mb620, `horoscope` peut appeler un fournisseur HTTP puis Claude pour
  localiser la prevision. La commande longue passait donc par CommandAsync,
  mais l'alias historique `horo` appelait encore `mbHoroscope_ctx` directement :
  un `m horo lion` pouvait bloquer la boucle IRC pendant les appels reseau.
- `horoscope` et `horo` utilisent maintenant le meme label canonique
  `horoscope` dans `run_ctx_async` : meme worker, meme verrou de canal, meme
  timeout et meme facade de sortie. L'aide de `horo` annonce aussi correctement
  qu'un signe peut etre fourni, comme pour la commande longue.
- Nettoyage de documentation : le commentaire de repliement des signes ne
  pretend plus que `Horoscope.pm` est sans `use utf8` depuis mb621.
- Nouveau test 805 : les deux dispatchs passent par CommandAsync avec le meme
  label, aucun alias synchrone ne subsiste, aide longue/courte coherente.

### mb621 — encodage de sortie : la vraie cause, et la classe entiere fermee
- Mon correctif mb620 avait AGGRAVE le probleme : une seule expression etait
  cassee avant, toute la ligne l'etait apres. Diagnostic complet cette fois :
  mediabot.pl DECODE les messages entrants (~ligne 2089), donc $nick, $target
  et les arguments sont des chaines de CARACTERES ; l'envoi n'encode QUE si
  la chaine est marquee utf8 ; or un fichier sans « use utf8 » a des
  litteraux en OCTETS. Interpoler une variable marquee dans un tel litteral
  fait basculer TOUTE la chaine : les octets sont relus en latin-1 puis
  re-encodes a l'envoi — double encodage. Rien a voir avec mediabot.conf.
- Correction de la CLASSE, pas du symptome : « use utf8 » pose sur les 15
  modules dont les litteraux non-ASCII peuvent partir sur IRC (106 litteraux
  concernes au total ; la commande actualites portait la meme bombe). Les
  litteraux deviennent des caracteres, l'envoi encode une fois, la sortie est
  juste quel que soit ce qu'on interpole.
- Bugs revele par la correction, corriges dans la foulee :
  * un signe accentue TAPE SUR IRC n'etait pas reconnu (« horoscope bélier »
    arrive DECODE, mon repliement ne connaissait que les octets) — le
    repliement accepte desormais les deux mondes ;
  * une substitution avec un echappement de trop (\/\/ au lieu de //)
    SUPPRIMAIT silencieusement le caractere au lieu de le replier ;
  * deux cles de passerelle ecrites en octets cassaient l'aller-retour de
    Bélier et Gémeaux.
- Test 804 (29 assertions) : garde structurelle « tout module qui emet du
  non-ASCII declare use utf8 », et surtout SIMULATION DU FIL — la regle
  d'envoi reelle est rejouee sur la sortie de l'horoscope avec un pseudo
  DECODE (le cas de production), puis les octets sont re-decodes en strict
  pour prouver qu'ils sont de l'UTF-8 valide, sans aucune sequence de double
  encodage. Cette classe de bug ne peut plus revenir sans faire rougir la
  suite. Tests 700 et 803 alignes sur le monde correct.

### mb620 — horoscope : accents corriges, signe reconnu, prevision reelle
- MOJIBAKE (« humeur Ã©lectrique », capture #boulets) : UserCommands.pm n'a
  PAS « use utf8 », donc ses accents sont des OCTETS, tandis que "\x{26A1}"
  cree un CARACTERE large. Toute chaine melant les deux est double-encodee a
  l'affichage. Sept litteraux etaient dans ce cas (pool d'humeurs) et le
  tableau des signes portait le meme defaut latent — il aurait casse des
  qu'un signe francais s'affichait. Tous les \x{...} de ces deux zones sont
  convertis en caracteres litteraux : plus aucune chaine du fichier ne mele
  les deux mondes, et le test le verifie sur l'ENSEMBLE du fichier.
- Nouveau module Mediabot/External/Horoscope.pm : reconnaissance d'un signe
  ecrit par un humain (francais, anglais, espagnol, accentue ou non, glyphe,
  abreviation) et prevision quotidienne reelle depuis une API publique SANS
  CLE. La commande passe en worker (appel reseau).
- Les trois cas demandes sont couverts : « horoscope lion » (signe donne, il
  gagne sur la date de naissance stockee), « horoscope SaYa » (pseudo, signe
  deduit de USER.birthday), « horoscope » seul (soi-meme). Le signe est teste
  AVANT le pseudo, mais un pseudo ordinaire n'est jamais pris pour un signe.
  Sans signe connu, une invite discrete remplace l'ancien silence.
- GARDE-FOU CENTRAL : la reponse de l'API doit concerner le signe DEMANDE.
  Un fournisseur qui ignorerait son parametre servirait le meme signe a tout
  le monde — exactement le genre de detail qui fait rire un canal aux depens
  du bot. Reponse non conforme : ignoree, journalisee, horoscope local seul.
  Deux fournisseurs sont essayes dans l'ordre, la conf peut les remplacer.
- Best-effort de bout en bout : API muette, JSON casse, champ absent,
  traduction indisponible -> aucune ligne supplementaire et AUCUN message
  d'echec a l'utilisateur. Sur canal fr/es la prevision est traduite par
  claudeAI ; si la traduction echoue, on prefere ne rien afficher plutot
  qu'une phrase anglaise au milieu d'un horoscope francais.
- Un signe demande explicitement entre dans la graine du tirage local, sinon
  « horoscope lion » et « horoscope vierge » rendaient la meme saveur au meme
  utilisateur (contrat mb444/test 659 inchange sans signe force).
- Conf : section [horoscope] (API_URL, TIMEOUT), aucune cle requise.
- Test 803 (25 assertions) : absence totale de litteral mixte, reconnaissance
  des trois langues sans faux positif sur les pseudos, aller-retour des 12
  signes avec le tableau canonique, les trois cas en RENDU REEL, garde-fou du
  mauvais signe, et les quatre modes de panne.

### mb619 — les news affichées sont vraiment celles du moment
- Le RSS mb618 rendait enfin de vrais titres, mais la requête sans sujet cherchait
  littéralement « actualités importantes du jour en France ». Google News pouvait
  alors classer par pertinence des pages de juillet ou d'avril devant les dépêches
  du 8 août. La commande sans sujet utilise désormais le flux localisé **Top Stories**
  (`FR/ES/EN`) au lieu d'une recherche textuelle.
- Une source visible doit maintenant avoir une `pubDate` exploitable et réellement
  fraîche : 36 h maximum pour `m actualites` sans sujet. Les recherches thématiques
  utilisent `when:1d`, puis `when:3d`, puis `when:7d` uniquement si nécessaire.
  Les articles futurs incohérents et les dates inconnues sont exclus de la vitrine.
- Les faux « articles » de type fil d'actualité, info en continu, journal des
  informations, live updates/top stories sont filtrés de la liste cliquable.
- Le prompt Claude est désormais **ancré sur les trois titres cliquables** : Tavily
  ne peut plus faire partir la synthèse sur un sujet sans lien avec les références
  affichées ; il sert de matière de corroboration/contexte pour ces mêmes sujets.
- Nouveau test 802 : Top Stories pour le défaut, `when:` pour un sujet, exclusion
  des vieux/génériques/sans date, élargissement 1→3→7 jours et alignement du prompt.

### mb618 — les liens news pointent vers de vrais articles, pas des rubriques
- Le rendu mb617 etait enfin lisible, mais les titres exposes venaient encore
  de Tavily. Sur une recherche generale, Tavily remonte parfois une page de
  rubrique ou une homepage (`Journaux d’information`, `Actualites Ile-de-France`,
  etc.) : le lien etait cliquable mais n'annoncait pas precisement l'article.
- Architecture alignee sur `news_teuk.tcl` : Tavily reste la matiere factuelle
  de la synthese Claude, tandis qu'un Google News RSS localise (FR/ES/EN)
  fournit jusqu'a trois vrais titres de presse avec editeur et date pour la
  liste cliquable. En cas d'echec RSS, repli automatique sur les resultats
  Tavily existants — la commande ne depend donc pas de Google News pour vivre.
- Les titres RSS sont aussi injectes comme contexte secondaire dans le prompt
  afin d'aider la synthese a nommer les developpements precis plutot que les
  rubriques generiques. Le suffixe ` - Editeur` ajoute par Google News est
  retire puisque l'editeur est deja affiche dans la charte.
- La diversite se fait maintenant par editeur RSS et non par `news.google.com`,
  puis les URLs Google News sont raccourcies comme les liens Tavily. Aucune
  nouvelle cle API ni aucun schema de base.
- Nouveau test 801 : URL RSS localisee, parsing XML/entites/date, suppression
  du suffixe editeur, diversite des sources, titres precis dans la charte et
  preuve du repli Tavily.

### mb617 — actualites retrouve la charte visuelle et des liens utiles
- Le portage mb613 etait fonctionnel mais trop austere sur IRC : une synthese
  courte suivie d'une simple ligne « Sources: domaine (date) ». Cela disait
  d'ou venait l'info, mais pas OÙ cliquer, et on perdait l'ergonomie du
  script Windrop d'origine.
- La sortie reprend maintenant la charte qui a fait ses preuves : badge
  `Actu/News/Noticias` sur la synthese, puis une ou plusieurs lignes
  d'articles au format visuel `dd/mm domaine titre URL`, avec date et
  source en gris, separateur orange et lien bleu souligne.
- Les liens de source sont raccourcis via TinyURL (repli sur l'URL d'origine
  en cas d'echec) pour rester lisibles sur IRC sans exploser la longueur des
  lignes. Le raccourcisseur a son propre timeout court afin de ne pas manger le
  budget de 45 s du worker asynchrone.
- Comme dans `news_teuk.tcl`, seul le premier paragraphe de synthese porte le
  badge colore ; la seconde ligne reste legere, puis les references arrivent
  avec date/source en gris et URL bleue soulignee. Quand Tavily le permet, les
  trois references privilegient trois domaines distincts.
- La synthese reste bornee a deux lignes ; jusqu'a trois articles sources
  sont ensuite exposes. Si la construction des lignes article est impossible,
  le repli deterministe `Sources: domaine (date)` est conserve.
- Nouveau test 800 (16 assertions) : segments article avec charte IRC,
  emballage sur une ou plusieurs lignes, presence des tinyurl, et preuve que
  la sortie runtime privilegie les liens sources sur la ligne `Sources:` brute.

### mb616 — les garde-fous de news tiennent aussi entre alias et fenêtres
- Le cooldown parent de 45 s était déclaré sur les quatre alias mais son état
  restait indexé par le nom tapé : `actualites -> news -> actu -> actualite`
  permettait donc quatre appels payants successifs. Les alias partagent
  désormais réellement le bucket canonique `actualites`, y compris pour les
  overrides `.cmdcooldown`.
- `MIN_FRESH=2` était documenté mais la boucle Tavily s'arrêtait au premier
  résultat non vide. Elle élargit maintenant réellement la fenêtre tant que
  deux résultats datés de moins de 7 jours ne sont pas disponibles ; un
  résultat sans date reste utilisable en dernier recours mais ne prétend plus
  être « frais ».
- Hygiène tests : le nouveau test news mb613 est renuméroté 799 afin de ne plus
  doubler le numéro 796 déjà occupé par la vérité async des achievements ; les
  tests 798/799 verrouillent le bucket partagé et la fraîcheur réelle.

### mb615 — la sortie d'un worker est capturee quel que soit le chemin d'appel
- INCIDENT (prod #boulets) : « m actualités » demarrait bien son worker
  (« CommandAsync: 'actualites' worker started ») et ne repondait JAMAIS,
  sans la moindre erreur. Cause : les facades du worker n'etaient posees que
  sur les alias IMPORTES par Mediabot::UserCommands. External::News appelle
  la forme QUALIFIEE Mediabot::Helpers::botPrivmsg — ces appels partaient
  donc vers la vraie socket depuis l'ENFANT, qui ne doit jamais y toucher, et
  le POSIX::_exit final jetait le tampon. Toutes les commandes asynchrones
  existantes vivant dans UserCommands, le trou n'avait jamais mordu.
- La facade couvre desormais le glob SOURCE (Helpers) *et* l'alias importe
  (UserCommands) : un alias importe est un glob DISTINCT, poser l'un ne
  couvre pas l'autre. Tout module appele depuis un worker est protege, y
  compris ceux a venir.
- Corollaire du meme piege, corrige dans la foulee : le cooldown et le cache
  que mb613 posait DANS le module etaient un trompe-l'oeil — un compteur
  ecrit dans $self meurt avec le processus fils. Le garde-fou de frequence
  vit maintenant cote parent (checkCmdCooldown, 45 s) et couvre les QUATRE
  alias : sans cela on le contourne en tapant 'news' juste apres
  'actualites'. Le cache de reponses, qui n'aurait jamais servi, est retire
  plutot que laisse en decoration.
- Test 798 (16 assertions) : capture des deux chemins d'appel et des trois
  genres, absence de fuite vers les vrais helpers pendant la collecte,
  RESTAURATION des globs a la sortie (le rejeu parent doit repasser par les
  vrais helpers, sinon le bot se parle a lui-meme), bornes et exceptions
  inchangees, couverture du cooldown sur les 4 alias, et absence de tout
  compteur pose dans le worker.

### mb614 — une commande accentuee atteint enfin sa table
- INCIDENT (prod #boulets) : « m actualités » ne declenchait RIEN, le log
  montrant la commande en mojibake (« actualitÃ©s »). Cause : Mediabot.pm a
  « use utf8 », donc la cle litterale 'actualités' posee en mb613 etait une
  chaine de CARACTERES (é = U+00E9) alors qu'IRC livre des OCTETS utf-8
  ("actualit\xC3\xA9s"). Aucune correspondance possible : la commande
  tombait silencieusement dans le chemin des commandes inconnues.
- Correction A LA RACINE plutot qu'au cas par cas : _fold_command_name()
  replie tout nom de commande sur sa forme ASCII minuscule — octets utf-8,
  chaine deja decodee, latin-1, majuscules — et le repliement est applique
  AVANT toute recherche, en public comme en prive. Un nom deja ASCII ressort
  inchange, donc le chemin normal ne paie rien. La prochaine commande
  accentuee marchera sans qu'on y pense.
- La table ne contient plus AUCUNE cle non-ASCII : elles ne pouvaient de
  toute facon jamais matcher.
- Les cinq formes demandees repondent : actualités, actualité, actualites,
  actualite, news (plus la forme courte actu). Singulier et pluriel sont le
  meme geste ; chaque alias a son entree d'aide.
- Test 797 (21 assertions) : repliement depuis chaque encodage, les 5 formes
  verifiees comme atteignant une cle REELLEMENT presente au dispatch, ordre
  repliement-puis-recherche, absence de cle accentuee, robustesse (undef,
  vide, reference, octets indecodables : une valeur rendue, aucune mort, et
  aucune commande atteinte). Pin 796 evolue en consequence.

### mb613 — !actualites : recherche Tavily + synthese dans la langue du canal
- Portage du news_teuk.tcl (Windrop) dans le moule mediabot. Nouveau module
  Mediabot/External/News.pm, commande publique actualites (alias actualités,
  actu, news), routee via CommandAsync : deux appels reseau a la suite ne
  doivent pas figer la boucle d'evenements.
- La langue vient de l'API PARTAGEE mb609 (jeton force en|fr|es ou lang=xx,
  sinon langue du canal, sinon main.LANG) : aucune regle de langue n'est
  recopiee. Les textes de service existent dans les trois langues avec repli
  anglais, et la synthese est demandee dans la langue resolue.
- SANS SUJET, la commande cherche vraiment les actualites du jour (requete
  par defaut propre a la langue) au lieu de repondre qu'elle n'a pas de quoi
  resumer, et la fenetre temporelle S'ELARGIT par paliers reellement
  distincts (day -> week -> month cote Tavily, 1 -> 3 -> 7 jours cote
  vertical news) tant qu'il n'y a pas de matiere.
- Pas de vieux articles : les resultats sont tries du plus recent au plus
  ancien et ceux de plus de 7 jours sont ecartes DES QU'il reste assez de
  matiere fraiche — mais jamais au prix du silence, et chaque source est
  affichee avec sa date pour que le lecteur juge.
- La ligne « Sources: domaine (date) » est construite DETERMINISTEMENT depuis
  les resultats Tavily, dedupliquee et bornee : le modele ne peut pas
  halluciner une source. Si la synthese echoue, les titres eux-memes servent
  de repli plutot qu'un message d'echec.
- Le francais et l'espagnol interrogent le topic 'general' avec country
  (la presse locale remonte mal dans le vertical news, paywalls) ; l'anglais
  utilise le vertical news. Domaines bruyants exclus, cooldown 45 s et cache
  5 min par salon, comme le script d'origine.
- Conf : section [tavily], cle API_KEY (commentee dans le sample — AUCUNE
  cle n'entre dans le depot). Sans cle, la commande le dit et s'arrete.
- Test 796 (47 assertions) : routage des 4 alias, textes des 3 langues,
  requetes par defaut, paliers reellement croissants, tri et ecartement des
  vieilleries sans jamais rendre le silence, resultats sans date acceptes,
  ligne Sources deterministe/dedupliquee/sans date inventee, refus explicite
  sans cle, et absence de cle dans le code comme dans le sample.

### mb613 — la progression async revient vraiment au parent
- Correction d'un ecart entre les tests directs et le runtime : les checks
  lourds d'achievements tournent dans un worker forké ; les set_progress()
  faits dans ce child modifiaient seulement sa memoire copy-on-write puis
  disparaissaient. msg_count et channels_active reviennent desormais dans le
  resultat borne du worker et sont appliques par le parent.
- Le worker honorait aussi les seuils par defaut uniquement, car son objet bot
  est volontairement reduit au handle DB isole. Les seuils EFFECTIFS (y
  compris les surcharges [achievements]) sont maintenant snapshots avant fork.
- Le compteur de canaux deja calcule par le check polyphony nourrit enfin
  channels_active au lieu d'etre jete apres le test d'unlock.
- Les descriptions du catalogue ont ete alignees sur les nouveaux seuils
  par defaut mb611 (150k messages, 300 trivia, 250 karma, etc.).
- Hygiene : suppression effective de l'ancien
  t/cases/790_mb608_ai_summary_language.t, remplace par 791 depuis mb609.
- Test 796 : passage parent/worker des progressions, seuil configure dans le
  worker, polyphony enregistre, descriptions alignees.

### mb612 — la progression devient visible, et la grille est complete
- Le catalogue declare desormais QUEL compteur mesure chaque achievement
  (progress_kind). 20 des 24 sont mesurables ; les 4 autres (sniper,
  underdog, night_owl, early_bird) se declarent NON mesurables au lieu
  qu'on leur fabrique une progression qu'on ne sait pas calculer.
- Les valeurs deja connues des verifications sont enregistrees dans le
  registre mb610 par set_progress — nombre de messages, karma, karma
  donne, mots distincts, canaux frequentes. AUCUNE requete supplementaire :
  ces nombres etaient deja calcules, ils etaient simplement jetes. La
  valeur d'etat est monotone : une lecture plus basse (fenetre glissante,
  purge) n'efface pas un merite deja constate.
- Nouvelles lectures : progress_snapshot (debloque, valeur, seuil,
  pourcentage borne, mesurable ou non) et next_goals (les N objectifs
  verrouilles les plus PROCHES). Un palier deja atteint mais pas encore
  enregistre n'est jamais propose comme objectif — « 137/10 (100%) »
  n'est pas une chose a faire.
- !achievements gagne une ligne « Next: » avec les 3 objectifs les plus
  proches et leur pourcentage ; la vue « aucun achievement debloque »
  montre enfin ce qui est a portee, ce qui est precisement le moment ou
  la commande doit servir. Vue cross-canal exclue : la progression se
  compte par canal, l'afficher a cote d'un total cross-canal tromperait.
- Nouvelle vue !achievements progress [nick] : la grille complete, du plus
  proche au plus lointain, barre de 12 cases, nombres lisibles (4.2k,
  150k), bornee a 12 lignes en notice avec un compte des restants.
- .status partyline : « Achv: N profile(s), M progress counter(s) » et
  « (unsaved changes) » le cas echeant — le registre est le seul etat du
  systeme qui ne se recalcule pas, l'operateur doit le voir.
- Test 795 (32 assertions) dont le RENDU REEL des trois vues capture
  ligne a ligne. Piege consigne : UserCommands importe botPrivmsg/botNotice,
  c'est SON alias qu'un test doit remplacer, pas celui de Helpers.

### mb611 — le merite exige croit avec la rarete, et se regle sans coder
- Les seuils vivent desormais DANS le catalogue %ACH (champ threshold) :
  la definition d'un achievement et sa verification ne peuvent plus
  diverger, et plus aucun nombre n'est ecrit en dur dans les checks.
- Chaque seuil est reglable par conf, section [achievements], cle =
  identifiant en MAJUSCULES (TRIVIA_CHAMPION=200). Valeur absente, non
  numerique, nulle ou negative : le defaut du catalogue s'applique.
- Reequilibrage des paliers rares et au-dela : trivia_champion 100->300,
  quote_master 50->150, duel_master 50->150, quote_detective 10->20,
  matchmaker 10->25, karma_legend 100->250, gift_giver 100->250,
  polyglot 5000->7500, polyphony 5->8, underdog 5->8 defaites d'affilee,
  trivia_sniper <=3s -> <=2s, legend 100k->150k messages. Les paliers
  d'entree (first_msg, trivia_rookie, chatterbox, karma_star, night_owl,
  early_bird, duel_warrior, star_gazer, mood_reader, wordsmith) ne bougent
  pas : c'est la rarete qui se paie.
- Relever un seuil ne revoque RIEN : un achievement deja gagne est un fait
  enregistre, pas un calcul refait.
- Pin 665 evolue (il verrouillait un 50 litteral ; il verrouille desormais
  la SOURCE du seuil et sa valeur par defaut). Test 794 (17 assertions) :
  catalogue complet, absence de seuil en dur, surcharge conf et garde-fous,
  monotonie des paliers dans chaque famille, hausse effective des rares+,
  seuil inverse du sniper, non-revocation apres durcissement.

### mb610 — la progression vers les achievements survit au redemarrage
- Diagnostic : les unlocks etaient bien persistes (var/achievements.json),
  mais les COMPTEURS qui y menent ne l'etaient pas. horoscope, compat, mood
  et duels vivaient dans des tables memoire du bot ; pire, trivia et
  quotegame recevaient le score de la PARTIE en cours — « 100 bonnes
  reponses » exigeait donc 100 reponses dans une seule session, et
  « 50 quotegame » repartait a zero a chaque partie. Ces paliers n'etaient
  pas difficiles : ils etaient inatteignables.
- Nouveau registre de progression PERSISTANT dans le meme fichier JSON
  (aucune modification de schema) : { kind => { "lc(nick)\0lc(canal)" => n } },
  API progress / bump_progress / progress_for_nick. Cle canonique en
  minuscules pour le nick ET le canal, et merite compte PAR CANAL puisqu'un
  achievement se debloque par canal.
- Format de fichier v2 { version, profiles, progress }, avec lecture
  transparente des fichiers HERITES a plat : aucun unlock existant n'est
  perdu, le fichier repart en v2 au premier save.
- Plafond $MAX_PROGRESS_ENTRIES (5000 par type) : au-dela, ce sont les
  compteurs les PLUS FAIBLES qui tombent — et jamais celui qu'on vient
  d'incrementer (sans cette garde, une entree neuve pouvait etre elaguee
  dans la foulee de sa creation et ne jamais decoller).
- Les six familles de compteurs passent par le registre, avec repli
  silencieux si le systeme d'achievements est absent. L'affichage des jeux
  (score de la partie) est inchange : seul le hook recoit le cumul.
- Test 793 (26 assertions), dont la persistance REELLE verifiee par une
  seconde instance relisant le fichier — c'est-a-dire un redemarrage.

### mb609 — 'recap ai' rejoint la regle de langue, par la MEME implementation
- La regle de langue de mb608 est extraite de claude_ctx en API publique du
  module Claude : extract_ai_lang_token (jeton nu en|fr|es ou lang=xx),
  resolve_ai_lang (force > langue du canal mb563 > 'en'), ai_lang_name et
  ai_lang_text (vocabulaire de service partage). 'ai summary' consomme
  desormais ces fonctions au lieu de sa regle en ligne : les deux commandes
  ne peuvent plus diverger, et une future langue s'ajoute en un seul point.
- 'recap ai' suit la langue du canal et accepte le meme forcage :
  recap 2h ai fr, recap ai lang=en. Un code hors trio previent l'appelant.
- Le prompt de recap demande EXPLICITEMENT la langue. L'ancienne formule
  « in the same language as the conversation » laissait le modele deviner —
  sur un canal bilingue, le resume tombait au hasard.
- Les trois messages de service du chemin IA (resume indisponible, IA non
  configuree, resume tronque) sont localises, avec repli sur la formulation
  anglaise historique.
- Le module Claude etant charge PARESSEUSEMENT, recap passe par can() comme
  le fait deja son chemin IA : sans le module, aucun jeton n'est extrait et
  la langue reste celle du canal — comportement historique intact.
- Hygiene : le test de mb608 est renumerote 791 (deux fichiers portaient le
  prefixe 790 apres la passe mb607 ; c'est le mien qui bouge).
- Usage et ligne de commande publique mis a jour. Test 792 (29 assertions) :
  API unitaire (extraction, resolution, casse, hors-trio, repli, cle
  absente), consommation par recap via can(), absence de regle recopiee,
  prompt explicite, 3 messages localises avec repli, syntaxe annoncee.

### mb608 — 'ai summary' parle la langue du canal (et sait etre force)
- La reponse suit desormais la langue du canal : les chansets LangFR /
  LangES (mb563, Helpers::channel_lang) decident, et a defaut main.LANG
  s'applique — dont le defaut est 'en'. AUCUN canal existant ne change de
  comportement : l'anglais reste le defaut historique.
- Forcage explicite par jeton positionnel, dans la meme passe que
  public / <N>l / help : 'ai summary today fr', ou la forme non ambigue
  'lang=fr'. Le jeton est extrait AVANT le parsing du filtre nick. Pour
  pouvoir malgre tout cibler un pseudo homonyme d'une option (fr/en/es,
  public, help...), 'nick=<pseudo>' fournit un echappement explicite.
  Un code hors trio (en|fr|es) previent l'appelant et retombe sur la
  langue du canal.
- Les messages de service sont traduits eux aussi ('Resume de 12
  message(s) (aujourd'hui) sur #chan...', 'Aucun message trouve...'),
  libelles de periode compris, y compris les formes a parametre
  (depuis 2h05m, 7 derniers jours).
- Le PROMPT garde ses metadonnees en anglais et ne gagne qu'une
  instruction de langue : le comportement de resume est inchange a la
  lettre, seule la langue de sortie bouge.
- .ai summary help documente la langue ; la ligne de commande publique
  annonce [en|fr|es] (pin 630 evolue).
- Test 790 (33 assertions) dont une SONDE EXECUTABLE : la passe grep est
  extraite du source et reellement executee sur des arguments realistes
  ('today fr', 'today teuk', '7d 3l public lang=es SlaY', 'lang=de'), ce
  qui prouve qu'un pseudo ordinaire n'est jamais pris pour une langue et
  que le jeton coexiste avec toutes les autres options.

### mb607 — garde pre-commit de l'outil plugin offline
- Le dry-run est rendu explicite : seules les ACTIONS Mediabot ne sont pas
  appliquees. `run` execute bien le script comme un vrai subprocessus et
  n'est PAS un sandbox ; un script de confiance conserve les droits OS du
  compte qui lance l'outil.
- Le sidecar n'est plus pre-lu par l'outil pour deviner son nom. Le premier
  lecteur est desormais le vrai PluginManager (chemin, borne, JSON, identite),
  puis les overrides `--config` sont appliques par un vrai replace load.
- Les fixtures d'events reproduisent les `event_type` du coeur : `join`,
  `part`, `topic`, `kick`, `nick`, `quit`, `cron`; `public_command_observed`
  transporte command/args sans event_type. Si la whitelist routable grandit
  sans fixture correspondante, l'outil refuse de mentir.
- `--storage` passe par le vrai `validate_storage_object` avant d'alimenter
  `data.storage`. Les commandes a niveau (ex. Master) restent testables mais
  l'outil annonce clairement que USER_LEVEL n'est pas emule hors ligne.
- Nouveau test 790 + cookbook pour verrouiller ces garanties de fidelite.

### mb606 — tools/mb_plugin_dev.pl : valider un plugin v2 sans lancer le bot
- Le chainon manquant du confort d'auteur : depuis l'arc v2, ecrire un
  plugin exigeait un bot en marche (et donc une base, un reseau, un
  canal) pour savoir si le sidecar passait. L'outil valide et EXECUTE un
  script hors ligne, sans base, sans IRC, sans rien ecrire.

      tools/mb_plugin_dev.pl validate examples-v2/karma.py
      tools/mb_plugin_dev.pl run examples-v2/karma.py --command thanks \
            --nick aur --arg SlaY --storage /tmp/state.json
      tools/mb_plugin_dev.pl run examples-v2/daily.tcl \
            --event plugin_cron_observed --config CHANNEL='#dev' \
            --config TEXT='Morning!' --data hour=9 --data minute=0

- REGLE DE CONCEPTION, et tout l'interet : l'outil ne reimplemente AUCUNE
  regle. Il monte le vrai PluginManager, le vrai ScriptRunner et le vrai
  ScriptActionRunner derriere un bot hors ligne minimal — bornes, refus,
  fusion de config, routabilite des events, tout vient du code que le bot
  execute. Meme la taille limite affichee pour un store est LUE dans
  $Mediabot::ScriptActionRunner::MAX_STORE_BYTES, jamais recopiee : le
  test 789 verifie qu'aucune borne du contrat n'est en dur dans l'outil.
- Les actions sont PLANIFIEES (apply => 0) : l'outil montre ce que le bot
  ferait — un store affiche son document et sa taille — et n'applique
  rien. Codes de sortie 0/1 exploitables en pre-commit ou en CI.
- Le contexte est construit comme dans le bot, depuis les DONNEES de
  l'evenement : un event reseau (cron, quit, nick) n'a pas de canal, donc
  un target explicite passe. Premiere version de l'outil refusait a tort
  l'annonce de daily.tcl — le piege est desormais verrouille par un test.
- Cookbook regle 9. Test 789 (23 assertions) : compilation, usage, les
  trois exemples reels du depot valides, message d'erreur EXACT du
  PluginManager sur sidecar invalide, absence de borne recopiee,
  execution reelle avec et sans --storage, event reseau avec target
  explicite, event non declare refuse, et aucun repertoire de donnees
  cree par l'outil.

### mb605 — garde pre-commit mb603-mb604 : date, plafonds et verite des gauges
- `plugin_cron_observed` transporte maintenant `year` et son stamp interne
  contient la date complete. `daily.tcl` memorise `year-month-day` : le 4 aout
  2027 n'est plus confondu avec le 4 aout 2026.
- `karma.py` respecte reellement `MAX_TRACKED=200` : si le nick tout juste
  remercie serait elimine par le tri, il remplace l'entree la plus faible au
  lieu de devenir une 201e cle.
- `mediabot_plugin_storage_bytes` est reconcilie a la lecture apres restart,
  remis a zero sur clear ou document invalide, et les symlinks/oversizes
  increments aussi `storage_read_invalid_total`.
- Le collecteur des refus de store ignore sans die les diagnostics mal formes ;
  l'observabilite reste best-effort et ne peut pas transformer un succes en
  echec de dispatch. Le chmod 0600 du fichier temporaire est desormais verifie.
- Pins 782/786/787 et nouveau test 788 (10 assertions) verrouillent les
  regressions ci-dessus.

### mb604 — l'observabilite de la persistance
- Quatre series decrivent desormais le storage mb601 :
  mediabot_plugin_storage_bytes{plugin} (GAUGE : la taille du document
  courant, elle REMPLACE et ne s'additionne pas — comme le document),
  mediabot_plugin_store_total{plugin} (ecritures appliquees),
  mediabot_plugin_store_rejected_total{plugin,reason} et
  mediabot_plugin_storage_read_invalid_total{plugin}.
- Les raisons de refus sont ramenees a un VOCABULAIRE BORNE
  (too_large, too_deep, too_many_keys, key_too_long, not_an_object,
  duplicate, no_sink, invalid_name, write_failed, other) : un label tire
  du texte d'erreur brut ferait exploser la cardinalite Prometheus. Les
  refus sont comptes aux DEUX endroits ou ils naissent — au PLAN (bornes
  du contrat, avant toute application) et a l'APPLICATION (gate fermee,
  second store du meme run, panne du sink).
- Un fichier local abime n'est plus seulement une ligne de journal : il
  devient une serie (read_invalid) tout en restant ignore.
- Discipline mb598 conservee : _pm_gauge/_pm_metric sont best-effort
  (eval + can) — sans sous-systeme metrics, le dispatch est inchange et
  rien ne meurt.
- Test 787 (19 assertions) : declaration des 4 sur un VRAI Metrics,
  ecriture reelle (compteur +1, gauge = taille reelle du fichier, la
  gauge remplace au 2e store), refus au plan par raison (too_large,
  too_deep) sans incrementer les ecritures, refus a l'application
  (duplicate) avec le PREMIER store bien ecrit, fichier hors contrat
  compte read_invalid, best-effort sans metrics, et la table de
  classification verifiee message par message.

### mb603 — la galerie prend vie : karma.py (storage) et daily.tcl (cron)
- Deux mecanismes majeurs livres sans vitrine trouvent enfin leur exemple.
  examples-v2/karma.py : l'exemple A ETAT que le cookbook declarait
  « hors protocole, volontairement sans etat » depuis mb524 — thanks
  <nick> / karma [nick], read-modify-write explicite sur data.storage,
  anti-abus (se remercier soi-meme ne stocke RIEN), et un plafond propre
  MAX_TRACKED=200 qui laisse tomber les plus discrets AVANT que le bot
  refuse le document : le motif « mon plafond sous celui du bot ».
- examples-v2/daily.tcl : trois mecanismes en huit lignes utiles —
  plugin_cron_observed (mb599), config operateur CHANNEL/HOUR/MINUTE/TEXT
  (mb600) et le dernier jour annonce en storage (mb601) pour qu'un
  redemarrage n'annonce jamais deux fois. LECON NEUVE documentee : un
  event cron n'appartient a AUCUN canal, donc la reply porte un target
  EXPLICITE tire de la config (la garde de portee mb524 ne contraint que
  les replies qui ONT un contexte de canal).
- Cookbook : galerie a jour, lecon du target cron ajoutee a la regle 6,
  et la phrase « le protocole est volontairement sans etat » corrigee —
  elle est fausse depuis mb601 ; un timer rebatit toujours depuis ses
  args, le storage est pour ce qui SURVIT au run.
- Test 786 (24 assertions) : chargement reel des 2 sidecars du depot,
  karma en EXECUTION REELLE via le pipeline complet (thanks persiste, 2e
  thanks relit frais et incremente, lecture n'ecrit rien, podium trie),
  anti-abus sans ecriture, 200 nicks passent les bornes du bot, daily
  reel sur les 4 chemins (annonce avec target explicite + memorisation,
  2e tick du jour = silence, autre minute = silence, non configure =
  silence), cookbook verrouille.

### mb602 — garde pre-commit mb598-mb601 : frontieres storage/info/diagnostics
- La persistance accepte maintenant les booleens JSON et reutilise UN SEUL
  validateur complet aux trois frontieres (plan, ecriture, lecture) : profondeur,
  nombre/longueur de cles et taille ne peuvent plus diverger. Les fichiers
  locaux trop profonds, invalides ou symboliques sont ignores et journalises.
- Le nom de storage est revalide comme slug avant resolution ou purge :
  `.plugins cleardata` ne peut plus traverser DATA_DIR. Les lectures et
  `.plugins info` ne creent plus le repertoire ; seul un vrai `store` le cree.
- `.plugins info` borne chaque texte sur une ligne et masque les cles de config
  susceptibles de contenir un secret (password/token/key/auth/credentials),
  sans masquer les champs ordinaires.
- Les erreurs ScriptRunner imbriquees dans `response.errors` restent visibles ;
  les echecs d application d actions comptent aussi dans
  `mediabot_plugin_script_failure_total` pour command ET event.
- Le greeter remplace `%s` comme placeholder LITTERAL : une formule operateur
  telle que `100% welcome, %s` ne peut plus etre interpretee comme programme
  `format` Tcl. Test 785 : booleens, bornes disque, traversal/symlink, lecture
  pure, redaction/injection, diagnostics/metriques et execution Tcl reelle.

### mb601 — chantier D : persistance KV par plugin (le bot ecrit, le script demande)
- Nouvelle action de protocole `{"type":"store","data":{...}}` : le script
  ne touche JAMAIS le disque ; le BOT applique via un store_sink injecte
  par le PluginManager (modele schedule_timer), gate allow_store fermee
  par defaut — les routes v1 sans sink echouent explicitement. Bornes
  validees au plan : objet JSON profondeur <=3, <=256 cles, cle <=64
  chars, serialisation canonique <=16384 octets ; UN SEUL store applique
  par run (le premier gagne, les suivants sont des erreurs).
- Fichier <DATA_DIR>/<name>.json (conf plugins.DATA_DIR, defaut
  plugin-data/ relatif au CWD, cree 0700), ecrit ATOMIQUEMENT
  (temp.$$ + rename), borne re-verifiee a l'ecriture. Lecture a CHAQUE
  dispatch : data.storage arrive FRAIS (l'inverse assume de data.config
  snapshotee — un compteur perime ne sert a personne) ; un fichier
  invalide est journalise et ignore, jamais un die sur le chemin d'un
  dispatch. Ecritures concurrentes : dernier ecrit gagne, documente.
- Partyline : .plugins cleardata <name> (Owner) purge l'etat ; .plugins
  info affiche « storage: N bytes (chemin) ». Cookbook regle 8.
- Sample conf : la section [plugins] devient ACTIVE (en-tete seul, cles
  commentees — aucune entree Config::Simple) pour que le garde-fou 615
  couvre plugins.DATA_DIR ; les pins 431/517 evoluent en verrouillant
  toujours l'esprit « rien d'actif » (unlike DATA_DIR= ajoute).
- Test 784 (19 assertions) : bornes du store, gates (sans sink=erreur
  explicite, un seul store, premier gagnant), atomicite structurelle,
  ROUNDTRIP REEL python (run 1 ecrit n=1, run 2 relit et ecrit n=2, le
  chemin event pousse n=3), cleardata (gate Owner, purge, inconnu), info
  storage, cookbook. Pins evolues : 413/416 (listes de types + store),
  774 (parseur + gate Owner), 781, 412/772/775 (.help), 431/517 (sample).

### mb600 — chantier B : config par plugin dans le sidecar
- Le sidecar gagne un bloc "config" : les DEFAULTS de l'auteur (<=32 cles
  MAJUSCULES [A-Z][A-Z0-9_]{0,31}, valeurs scalaires <=512 octets — memes
  bornes que _normalize_config_map du runner, mais FAIL-CLOSED a la
  validation : l'auteur apprend tout de suite). L'operateur surcharge
  n'importe quelle cle depuis la conf du bot en plugins.<name>.<KEY>,
  sans editer le script ; une surcharge invalide est ignoree avec trace
  et le defaut conserve — la conf de l'operateur n'empeche jamais un
  plugin de charger.
- La config effective est SNAPSHOTEE au load (meme philosophie que la
  config des routes v1 vs data.network frais, mb552) et .plugins reload
  relit sidecar ET surcharges. Elle voyage dans data.config aux DEUX
  dispatchs (commande et event) — le runner la normalisait deja, le
  protocole n'a pas bouge d'un octet.
- greeter.tcl devient la demo vivante : son sidecar declare GREETING ;
  posee dans la conf (plugins.greeter.GREETING = "..."), la formule
  configuree remplace le pool, %s recoit le nick — zero edition du
  script. .plugins info affiche la config effective (valeurs tronquees a
  60 chars). Cookbook regle 7.
- Test 783 (14 assertions) : 4 refus fail-closed, fusion
  defaults+surcharge, surcharge >512 ignoree defaut conserve,
  transmission aux deux dispatchs, plugin sans bloc = rien de transmis,
  reload relit les surcharges, greeter en EXECUTION REELLE tclsh avec la
  formule configuree, info + cookbook verrouilles.


### mb599 — chantier C : la surface d'evenements s'elargit (nick, quit, cron)
- observe_channel_event accepte nick et quit. Ce sont des evenements
  RESEAU — pas de champ channel, la meme realite que les id_channel NULL
  de mb582. nick : le ctx porte nick (ancien) + new_nick (nouveau) +
  is_self (le renommage du bot lui-meme est observable). quit : nick,
  ident/host, message (raison), is_self — et JAMAIS sur netsplit : NS1
  existe precisement pour eviter le travail cher en rafale, lancer des
  scripts hors process par dizaines pendant un split serait pire que les
  ecritures DB deja supprimees.
- Nouveau observe_cron_event : le bind time d'Eggdrop reincarne. Appele
  par le tick 5 s existant (eval-garde comme tout observateur), il emet
  plugin_cron_observed UNE fois par minute (garde _last_cron_stamp,
  jitter <= 5 s, no-op sans listener) avec minute/hour/dow/mday/month —
  le script decide si cette minute le concerne, exactement bind time.
- Le pont scripts suit : liste blanche routable + channel_nick_observed,
  channel_quit_observed, plugin_cron_observed ; _script_event_data laisse
  passer new_nick et les champs cron. Cookbook regle 6 mis a jour (liste
  + le motif « annonce quotidienne = deux tests sur hour et minute »).
- Pins 728 (mb529/535) evolues : quit n'est plus l'exemple de type refuse
  (mode le remplace, la garde demeure), six points d'emission au lieu de
  quatre. Test 782 (26 assertions) : nick/new_nick/pas-de-channel, quit
  avec raison, inconnu refuse, cron champs numeriques + une emission par
  minute, sidecar nick+cron accepte, new_nick et hour/dow traversent le
  pont en conditions reelles, cablages structurels (cron dans le tick,
  NICK old+new, QUIT jamais netsplit), cookbook verrouille.


### mb598 — observabilite du sous-systeme plugins v2 (chantier A)
- Quatre nouvelles metriques Prometheus declarees dans Metrics :
  mediabot_plugin_command_total{plugin,command} (dispatchs passes par le
  pont d'auth — un dispatch autorise dont le script echoue COMPTE),
  mediabot_plugin_command_denied_total{plugin,command} (refus du pont),
  mediabot_plugin_event_total{plugin,event} (events routes vers les
  scripts), mediabot_plugin_script_failure_total{plugin,kind} (echecs par
  kind command/event). Increments via _pm_metric best-effort : sans objet
  metrics, aucun die, dispatch inchange.
- .plugins info <name> en partyline : la fiche complete d'un plugin —
  identite (etat/kind/api/version), source (module ou chemin de script),
  description, commandes du manifest avec niveau + compteur d'appels +
  help, events avec compteur de routage. Mode LECTURE (comme
  loaded/config) : le parseur de verbes gated reste strictement intact.
  Usage et .help gagnent info ; pins 412/772/775 evolues avec le contrat.
- Test 781 (18 assertions) : declaration des 4 metriques (inc reellement
  incrementable sur le VRAI Mediabot::Metrics), compteurs en conditions
  reelles (autorise ×2, refus sans dispatch, event route, echec command
  ET event), best-effort sans metrics, fiche info rendue (compteurs
  vivants dedans, calls=3 car le dispatch autorise echoue compte), inconnu
  explique, garde parseur intact.


### mb597 — garde pre-commit mb592-mb596
- Le routage d'events sidecar accepte maintenant le vrai
  Mediabot::Context de public_command_observed : channel, target, nick,
  command et args scalaires traversent la frontiere JSON au lieu d'un
  contexte vide. Les contextes de canal restent limites a une liste blanche.
- Un manifest d'events refuse les doublons et echoue proprement si aucun
  EventBus complet (on/off) n'est disponible : plus de plugin event charge
  mais silencieusement inerte. Les erreurs ScriptRunner/apply_actions sont
  journalisees avec leurs diagnostics bornes.
- Le quatrieme repli synchrone CommandAsync (echec watch_process) alimente
  maintenant fallback_sync, comme les replis loop/pipe/fork.
- Le flood boot partyline ferme reellement le transport avec
  close_when_empty avant le nettoyage idempotent de session ; sans cela le
  stream IO::Async pouvait rester vivant avec une session deja supprimee.
- Documentation corrigee : six regles v2, actions reply/notice/log, contexte
  public_command_observed, et 35 assertions pour le test des exemples.
- Test 780 verrouille les contextes benis, doublons, EventBus absent,
  diagnostics et gardes structurelles ; les tests 778/779 couvrent le
  quatrieme fallback et la fermeture effective du stream.


### mb596 — durcissement du throttle partyline (anti-amplification + flood)
- Le rate limiter existant (10 lignes / 5 s par session authentifiee,
  exemption pre-auth conservee) repondait « Rate limit exceeded » a CHAQUE
  ligne au-dela de la limite : un collage accidentel de 1000 lignes
  recevait 990 refus — le throttle etait lui-meme un amplificateur.
- Nouvelles regles, limite INCHANGEE : le refus s'annonce UNE fois par
  fenetre, les lignes suivantes sont ignorees en silence (comptees) ; et
  au-dela de 3x la limite dans la meme fenetre (30 lignes), flood
  caracterise : la session est deconnectee proprement (message court +
  _close_session idempotent mb366, log niveau 1 avec login et volume).
- Compteurs cumules _rate_stats{hits, silent_drops, flood_boots} exposes
  au .status sur une ligne Throttle (memoire seule, contrat mb573).
- Test 779 (18 assertions) : rafale reelle a travers _handle_line — 10
  passent, la 11e recoit LE refus, 12..29 silencieuses (drops comptes,
  session vivante), la 30e deconnecte (stream ferme, session nettoyee,
  compteur, log niveau 1), nouvelle fenetre = reprise avec rate_warned reset et refus
  reposable, exemption pre-auth et ligne .status gardees
  structurellement.


### mb595 — .status voit les jobs CommandAsync
- La ligne Async du .status partyline : nombre de jobs en cours + detail
  par job ([label] canal pid duree ecoulee, tries du plus ancien au plus
  recent) + compteurs cumules depuis le demarrage (spawned, completed,
  timeouts, sync fallbacks, lock refusals). L'operateur voit d'un coup
  d'oeil le gros classement qui tourne en fond et l'historique de sante
  du sous-systeme.
- Compteurs poses aux cinq points du cycle CommandAsync : spawn du worker,
  succes (avant le rejeu des intents), timeout (chemin timed_out), les
  QUATRE replis synchrones (pas de loop / pipe / fork / watch_process),
  et le refus de verrou un-job-par-canal. Le record de job gagne le canal
  d'origine.
- Nouvelles fonctions de LECTURE Mediabot::CommandAsync::
  async_jobs_snapshot / async_stats_snapshot — memoire seule, contrat
  mb573 respecte a la lettre : .status ne lance rien, ne tue rien,
  n'attend rien (garde structurelle au test : ni kill ni waitpid ni DB
  dans la section).
- Test 778 (22 assertions) : snapshots unitaires (tri par anciennete,
  elapsed, compteurs absents = 0, liste vide), gardes structurelles des
  cinq points d'incrementation, rendu reel de la section sur un stream
  capture, et refus de verrou en conditions reelles via run_ctx_async
  (compteur incremente, code non execute, notice envoyee).


### mb594 — plugins v2 : greeter.tcl, l'exemple event-driven
- Nouvel exemple plugins/scripts/examples-v2/greeter.tcl : la vitrine du
  routage d'events mb593 — AUCUNE commande, un seul event declare
  (channel_join_observed) dans son sidecar ; chaque join lance le script,
  qui souhaite la bienvenue (pool de formules) et se tait sur le join du
  bot lui-meme (garde is_self, motif cookbook 6 « stay silent when
  misrouted »). Tcl core sans dependance, meme technique d'enveloppe que
  lart.tcl ; l'extraction is_self tolere "1"/1/true.
- COOKBOOK.md : le greeter rejoint la liste des exemples references.
- Test 777 (13 assertions) : sidecar strict pur-event, chargement reel
  depuis le depot (zero commande montee, un listener pose), EXECUTION
  REELLE tclsh des deux chemins (join utilisateur -> reply contenant le
  nick ; join du bot -> ok + zero action), unload retire le listener
  (zero fantome), reference cookbook.


### mb593 — plugins v2 : les events du manifest deviennent des routages reels
- Pour un script sidecar, chaque nom de "events" est desormais un
  ABONNEMENT : le PluginManager s'abonne sur l'EventBus au load et lance le
  script avec le nom d'event et un contexte borne (channel, nick, message,
  topic, kicked, is_self ; command/args pour public_command). Liste blanche
  %ROUTABLE_SCRIPT_EVENTS = ce que le bot emet aujourd'hui :
  public_command_observed + channel_{join,part,topic,kick}_observed ; un
  event hors liste est refuse au load avec la liste dans le message. Les
  plugins in-process ne changent PAS (ils s'abonnent eux-memes dans
  register(), leur liste reste informationnelle).
- Memes gates que les commandes (apply + allow_irc, topic/kick/ban fermes)
  mais PAS de notice en cas d'echec — un evenement n'a pas d'appelant a
  prevenir : l'echec va au journal, c'est tout. is_enabled verifie a
  CHAQUE evenement (disable = silence sans dechargement).
- Cycle de vie complet, dans le moule transactionnel mb591 : les
  abonnements suivent exactement les commandes montees — desabonnement a
  l'unregister (off() par reference exacte, discipline mb242 : zero
  listener fantome), replace sans doublon, rollback d'un sidecar devenu
  invalide RESTAURE les abonnements precedents (l'instance restauree route
  toujours, prouve au test).
- COOKBOOK chapitre 10 : regle 6 (events = vraies souscriptions, liste
  blanche, squelette greeter). Test 776 (27 assertions) : refus hors liste
  avec liste dans le message + zero demi-etat, meme manifest libre pour un
  module in-process, abonnement + routage reel via emit (event/contexte
  transmis, gates), echec au journal sans notice, disable/enable, replace
  sans doublon + nouvel event, rollback restaure et route, unload zero
  fantome, regle 6 verrouillee.


### mb592 — plugins v2 : les exemples et le cookbook
- Nouveau repertoire plugins/scripts/examples-v2/ : trois scripts complets
  avec leur sidecar, un par langage. fortune.pl (Perl : pools d'aphorismes
  par categorie ET une commande 'fortunes' declaree level "Master" — la
  demonstration vivante du pont d'autorisation : le refus tombe AVANT
  d'executer le script) ; coin.py (Python : pile ou face, plafond anti-abus
  1..10, motif cookbook 3) ; lart.tcl (Tcl core sans dependance, technique
  d'enveloppe minimale d'eightball.tcl — le clin d'oeil Eggdrop assume).
  Chaque script parle mediabot-script-v1 a l'identique des examples/.
- COOKBOOK.md : chapitre 10 « Plugin v2: declare your commands in a
  sidecar manifest » ajoute en fin de fichier (zero renumerotation des
  chapitres existants) — le contrat en six regles : sidecar obligatoire
  et valide, level 0 ou description USER_LEVEL (plus petit = plus fort),
  actions reply/notice/log (topic/kick/ban refuses a l'application),
  echecs sobres, cycle de vie = celui des plugins.
- Test 775 (35 assertions) : les trois sidecars charges par load_script_v2
  avec un VRAI ScriptRunner pointe sur plugins/scripts du depot (montage,
  niveaux portes par le registry — fortune Master) ; EXECUTION REELLE des
  trois langages via run_script (perl, python3, tclsh) avec verification
  ok + action reply non vide ; JSON strict et coherence name=basename ;
  regles cles du chapitre 10 verrouillees.


### mb591-B3 — alignement de la suite CI plugins v2
- Les pins historiques 470 et 772 acceptent le contrat courant :
  `Scalar::Util` importe maintenant `refaddr` avec `blessed`, et l'aide
  `.plugins` expose `loadscript`.
- La fixture 774 retourne le plan structure attendu par ScriptActionRunner.
- Le wrapper des commandes script ne dereference plus un resultat scalaire et
  accepte des diagnostics `apply_errors` sous forme de hashes ou de chaines ;
  les formes imbriquees recoivent un message generique sans faire tomber le
  dispatch. Le test 775 verrouille ces chemins.

### mb591 — plugins v2 : derniere garde pre-commit
- Le replace/reload devient transactionnel jusque dans le montage des
  commandes : l'ancienne entry et ses commandes sont restaurees si le nouveau
  montage echoue. L'etat enabled/disabled est conserve lors d'un reload reussi
  comme lors d'un rollback.
- Un manifest de module qui declare des commandes exige maintenant un vrai
  objet enregistre et un CommandRegistry disponible ; aucun plugin v2 ne peut
  rester charge avec une surface de commandes silencieusement absente.
- Les scripts v2 doivent exister comme fichiers reguliers au chargement. Le
  sidecar est valide contre les echappements par symlink et lu avec une borne
  REELLE de 8 Ko avant decode JSON (plus de slurp potentiellement illimite).
- Le resultat de ScriptActionRunner est verifie : `applied_ok=0` n'est plus
  transforme en faux succes ; l'erreur est journalisee et une notice sobre est
  envoyee au demandeur.
- L'aide partyline mentionne desormais `loadscript`. Test 775 : 22 assertions
  sur rollback, etat preserve, sidecar, objet/registry fail-closed et erreurs
  d'application.

### mb590 — arc plugins v2, increment 5 : les scripts externes rejoignent le contrat
- Un script Perl/Python/Tcl devient un plugin v2 via un manifest SIDECAR
  JSON obligatoire (<script>.manifest.json a cote du script), meme forme
  que le manifest in-process. load_script_v2 : chemin valide par
  validate_script_path du runner (memes gardes anti-traversal que toute
  execution), langage par extension, sidecar borne (8 Ko) et decode
  strictement, validation par _validate_manifest (method-check saute et
  documente — le mensonge d'un script se detecte a l'execution).
- L'entry porte kind=script + script_path ; montage, autorisation (pont
  mb589 partage — une commande 'Master' de script refuse un User avant
  meme de lancer le script), demontage et replace sont EXACTEMENT le cycle
  de vie des plugins in-process.
- Dispatch : run_script(path,'public_command', champs du ctx) — timeout,
  bornes stdout/actions du runner inchanges — puis apply_actions en vif
  avec apply+allow_irc SEULEMENT : les gates intrusives (topic/kick/ban)
  restent fermees par defaut (modele mb545/554/564). Echec du run = notice
  sobre au nick, aucune action appliquee, raison au journal.
- Partyline : .plugins loadscript <path> [name] (Owner) ; reload conscient
  du kind — un script se recharge en relisant son sidecar, meme rollback
  (sidecar devenu invalide = instance precedente toujours active).
- Test 774 (31 assertions) : chargement (kind/api/commandes), refus
  traversal/extension/sidecar absent/JSON invalide/trop gros, dispatch
  (chemin/event/nick/args transmis, apply=1 allow_irc=1 gates fermees),
  echec sans apply, pont d'auth (User refuse/Owner passe), replace relit
  le sidecar, unload demonte, pins partyline. Pin usage 412 etendu.
- L'ARC PLUGINS V2 EST COMPLET : manifest (mb586), montage (mb587), cycle
  de vie partyline (mb588), autorisation (mb589), scripts externes (mb590).

### mb589 — arc plugins v2, increment 4 : le pont d'autorisation
- Le contrat level devient auto-documente : 0 = commande publique, sinon
  une DESCRIPTION de la table USER_LEVEL de l'instance ('Owner', 'Master',
  'Administrator', 'User'...). Les entiers >0 du contrat mb586 n'ont
  JAMAIS ete montables (refus mb587) : ils recoivent un message de
  migration precis — aucun plugin existant ne casse.
- Les commandes a niveau se MONTENT desormais. Le wrapper verifie
  l'autorisation a CHAQUE dispatch (jamais figee au montage) :
  identification par get_user_from_message (le meme chemin que logBot),
  authentification exigee, niveau compare par checkUserLevel (semantique
  maison : plus petit = plus fort — un Owner passe une commande Master).
  Refus fail-closed de bout en bout : pas de message dans le ctx, user
  inconnu, non authentifie, niveau insuffisant ; notice « Access denied »
  au nick (silencieux si aucun contexte), trace niveau 3. L'entry registry
  porte le level declare.
- Pins d'epoque evolues : 770 (level hors bornes -> message de migration +
  nouveau cas description mal formee), 771 (le refus « auth bridge » a
  saute, remplace par la migration).
- Test 773 (21 assertions) : contrat (0/description/entier>0/mal formee),
  montage de la commande Master, dispatch complet — non authentifie refuse
  avec notice et methode non appelee, Owner passe Master, User refuse,
  sans message = refus silencieux, level 0 sans check, gardes
  structurelles (verification par dispatch, pont appele avec le level du
  manifest).

### mb588 — arc plugins v2, increment 3 : cycle de vie a chaud en partyline
- .plugins pilote desormais le cycle de vie : load <Module> [name],
  unload <name>, reload <name> (Owner), enable/disable <name> (Master+,
  comme .schedule). Refus expliques ; toute erreur de chargement est
  montree en clair — le die du PluginManager porte deja la raison precise
  (manifest rejete, collision, methode manquante).
- reload = VRAI rechargement : delete %INC puis load replace ; si le
  nouveau code echoue (require, manifest, register), le die tombe avant
  register_plugin — l'instance precedente reste enregistree et ACTIVE, ses
  commandes continuent de servir (rollback naturel, annonce « previous
  instance still active »).
- Validation : un replace de soi-meme n'est plus une fausse collision — la
  commande deja au registry est tolerée si son entry porte plugin=>meme
  cle (le montage mb587 l'etiquette) ; toute autre appartenance reste un
  refus.
- Liste enrichie (api=N, commands=...), usage et .help a jour. Contrat 412
  (mb173) evolue : les mutations existent mais UNIQUEMENT dans le bloc
  gate par niveau ; la section de lecture reste pure (garde structurelle).
- Test 772 (20 assertions) : gates par niveau (y compris niveau indefini),
  load reel avec annonce api/commandes, erreur affichee, disable/enable
  pilotent le silence, reload de bout en bout sur module DISQUE (le
  nouveau code sert), echec de reload = instance precedente vivante,
  unload demonte, usage/.help.

### mb587 — arc plugins v2, increment 2 : montage automatique des commandes
- Les commands du manifest se montent au load dans le CommandRegistry
  (source public) : handler wrapper qui verifie l'etat enabled du plugin a
  CHAQUE dispatch (disable = la commande se tait sans dechargement, trace
  niveau 4) puis appelle $object->command_<nom>($ctx) ; plugin/description/
  level portes par l'entry registry ; le chemin de dispatch existant
  (handler_for avant la table legacy, mb166) rend la commande vivante sans
  autre cablage. Montage atomique : un echec demonte ce qui vient d'etre
  monte, retire le plugin fraichement enregistre, et remonte l'erreur.
- Validation durcie : une commande declaree sans methode command_<nom> =
  manifest menteur, refuse AVANT register() ; level>0 refuse au MONTAGE
  avec message explicite — le pont d'autorisation USER_LEVEL (plus petit =
  plus fort) est l'increment suivant, d'ici la jamais une commande
  privilegiee sans controle. Ordre des refus : collisions d'abord, methode
  ensuite (diagnostic precis).
- Demontage sur tout le cycle de vie : CommandRegistry::unregister_command
  (retire l'entree + ses aliases, idempotent) ; unregister_plugin demonte
  AVANT le teardown objet ; replace avec objet different demonte l'ancien
  (les deux chemins, direct et load/defer) ; same-object refresh conserve
  les commandes et herite mounted_commands (discipline mb248). Une commande
  fantome serait le jumeau exact des listeners fantomes mb233.
- Test 771 (23 assertions) : montage+dispatch reels sur un vrai registry,
  disable/enable, unregister sans fantome, refus menteur (aucun demi-etat),
  refus level>0, same-object refresh, unregister_command unitaire (aliases,
  idempotence), garde demontage-avant-teardown. 770 adapte au durcissement.

### mb586 — arc plugins v2, increment 1 : le manifest
- Ouverture de l'arc v2 (cap 3.5). Un plugin v2 expose une sub manifest
  declarative : api=2, name (slug, anti-usurpation : doit correspondre au
  nom d'enregistrement), version, description, commands (slug + help +
  level 0..1200, collision refusee contre le CommandRegistry du bot ET
  contre les manifests des autres plugins), events (noms valides).
- Validation FAIL-CLOSED placee AVANT $module->register() : un manifest
  invalide ne produit aucun effet de bord (meme discipline que le refus de
  doublon mb233). Un module sans manifest reste un plugin v1 legacy,
  accepte tel quel (metadata api=1) — zero regression.
- L'entry porte manifest + metadata.api ; version/description de l'entry
  viennent du manifest quand il existe. Demo migre en v2 (0.002) : premier
  plugin dont la surface se lit sans ouvrir le code.
- Test 770 (25 assertions) : cas valide, 14 refus cibles, collision
  inter-plugins, compat v1, integration load_perl_module, garde
  structurelle validation-avant-register.
- Prochains increments annonces : montage automatique des commandes du
  manifest dans le CommandRegistry ; cycle de vie partyline
  (list/load/reload/unload) ; manifest sidecar pour les scripts externes
  (Perl/Python/Tcl) via ScriptRunner.

### mb585 — les logs du worker ne se perdent plus (relais par le pipe)
- Incident #quebec post-mb583 : « lb » termine en 40.30s (pile la borne
  max_statement_time=40) avec 2 lignes au lieu de 4, et AUCUN log du worker
  dans le journal — POSIX::_exit(0) sort sans vider les buffers du logger
  herite, donc le message decisif du gather (« ARCHIVE query failed ...
  live result kept ») etait perdu. Diagnostic a l'aveugle.
- L'enfant recoit desormais un logger-collecteur (borne MAX_WLOGS=40,
  surplus compte et annonce) ; les logs voyagent dans le resultat JSON
  (les deux chemins, succes et echec) et le parent les rejoue au reap via
  son vrai logger, prefixes « [worker <label>] », avant les messages.
  logBot reste non facade (ecritures DB via le dbh isole, correctes).
- Gardes 769 (+8) : collecteur unitaire (contenu, borne, surplus),
  branchement enfant, rejeu prefixe, embarquement dans les deux chemins.

### mb584 — normalize couvre aussi la table d'archive
- Verification terrain mb583 : le gel est mort (« lb » sur #teuk servi en
  0.48s ; pendant les 30 s du worker de #quebec, ticks reguliers, Hailo,
  cache — le bot vit). Le « Database error » a 30.01 s = READ_TIMEOUT du
  handle isole (defaut 30 s) : la requete de #quebec depasse car les index
  canon n'ont jamais ete crees. L'archivage massif seul ne suffirait pas :
  les gathers mb576 scannent vif ET archive, et l'archive (creee LIKE)
  herite des memes index bancals.
- tools/normalize_channel_log_indexes.pl : pipeline factorise en
  run_table($table) et applique aux DEUX tables — CHANNEL_LOG puis
  <ARCHIVE_DBNAME>.CHANNEL_LOG_ARCHIVE si configuree (nom valide par regex,
  presence verifiee via information_schema ; absente = message, pas
  d'erreur). Memes 4 index canon, memes ADD/DROP INPLACE LOCK=NONE, DROP
  toujours calcules sur l'etat projete par table. Code retour agrege.
- Gardes 759 (+9) : plus aucun ALTER en dur, archive par le meme pipeline,
  validation regex, information_schema, code retour. 761 evolue
  ($total_failed).

### mb583 — les commandes carriere quittent la boucle d'evenements
- Terrain Undernet : « m lb » sur la table vive de 5M lignes a tenu la
  boucle 60 s (SLOW PRIVMSG 60.60s, event loop stalled ~59.52s) avant que
  MariaDB ne tue la requete — le bot etait fige pour tous les canaux.
  C'etait le point 5 de la revue pre-commit, reporte deux fois.
- Nouveau `Mediabot::CommandAsync` (moule mb559/571) : la commande forke,
  l'enfant execute la sub INCHANGEE avec une connexion DB isolee
  (InactiveDestroy sur les handles herites, `SET SESSION
  max_statement_time=40` en borne dure) ; des facades locales collectent
  ses botPrivmsg/botNotice/botAction en INTENTS (bornes, tronques avec
  drapeau au-dela) — l'enfant ne touche jamais la socket IRC ; le parent
  rejoue les intents au reap via les vrais helpers, donc AntiFlood,
  NoColors et la file differee mb568 s'appliquent. logBot n'est pas
  facade : il ecrit via le dbh isole. Timeout 45 s TERM puis KILL, verrou
  « un gros job par canal », reap watch_process, fallback SYNCHRONE
  documente (commande de lecture : degrader vers l'historique vaut mieux
  qu'une commande morte).
- 16 entrees du dispatch wrappees : stats, top, streak, wordcount, when,
  profil/profile, dashboard, compat, compare, heatmap, milestone(s),
  leaderboard/lb, chronos/chrono/timeline. last et seen restent synchrones
  (LIMIT indexes). Tests 701/712 evolues (la cible du dispatch est
  inchangee, via le wrapper).
- Test 769 (41 assertions) : facade unitaire sans fork (ordre des intents,
  borne+truncated, exception capturee avec intents partiels, facades
  retirees apres), gardes structurelles du worker, cablage des 16 entrees,
  last/seen non wrappes.

### mb582 — verify NULL-safe : les quits reseau archivent enfin (VRAIE cause)
- La contradiction Undernet (« seul id_channel diverge : 3816 » vs
  « align: 0 ») etait le symptome d'un angle mort SQL partage : NULL = NULL
  n'est pas vrai, NULL <> NULL non plus. Les quits sont des evenements
  RESEAU — id_channel NULL par design (schema : DEFAULT NULL). Le VERIFY du
  bot (arch.id_channel = live.id_channel) ne pouvait donc JAMAIS valider un
  lot contenant des quits : sa tache nocturne butait silencieusement a
  chaque run et le stock ne descendait pas. Les lignes etaient IDENTIQUES
  (NULL des deux cotes), pas divergentes.
- Fix : toutes les comparaisons nullables passent en <=> (NULL-safe) — dans
  le VERIFY du bot ET de l'outil (toujours identiques ligne a ligne, garde
  768), dans l'align (NOT(<=>) couvre aussi un vrai NULL-vs-valeur), et
  dans le diagnose (field-level NULL-safe + compteur both-NULL explicite +
  grille de lecture « network-wide events »).
- Gardes test : <=> exige dans les DEUX verify, egalite stricte bannie,
  aucune divergence <> NULL-blind restante dans l'outil, both_null_chan
  affiche.

### mb581 — diagnose v2 + --align-archive-channel-ids (incident Undernet resolu)
- Le diagnose Undernet a parle : charsets identiques, 5000/5000 presents,
  ts/event/nick/host/texte identiques a l'octet — SEUL id_channel diverge
  (1184/5000 ok). Memes evenements, referentiel de canaux d'une autre
  epoque dans l'archive. Diagnose v2 : distribution du mapping
  (live.id_channel -> arch.id_channel) avec noms resolus dans CHANNEL et
  bornes ts par paire ; les requetes muettes affichent desormais errstr ;
  collation de table extraite correctement (l'ancienne regex attrapait
  celle d'une colonne).
- `--align-archive-channel-ids` : realigne l'ARCHIVE sur le vif (autorite :
  il joint la table CHANNEL courante) pour les lignes par ailleurs
  IDENTIQUES a l'octet — UPDATE de l'archive uniquement, le vif n'est
  jamais ecrit (garde testee) ; dry-run par defaut, --execute par lots de
  5000 avec budget max-per-run ; refuse --diagnose et --loop. Une ligne qui
  differe par autre chose qu'id_channel n'est jamais touchee.
- Gardes test : section align sans aucune ecriture de CHANNEL_LOG, identite
  a 5 champs exigee, extraction du VERIFY re-ancree (l'outil contient
  desormais d'autres COUNT sur la table d'archive).

### mb580 — mode --diagnose : expliquer un « verify failed » sans rien toucher
- Premier run reel sur Undernet : `verify failed: 1184/5000` — le VERIFY a
  fait son travail (aucune suppression du vif). `--diagnose` (LECTURE SEULE,
  refuse --execute) explique pourquoi : definitions des deux tables
  comparees (alerte explicite si les CHARSETS different — BINARY convertit
  avant de comparer, les lignes non-ASCII ne verifieraient jamais),
  repartition du premier lot en absent/identique/DIVERGENT avec le champ
  fautif (SUM par champ), echantillon de 5 lignes divergentes en HEX
  (ts live vs arch annote « DIFFERENT EPOCH? id reuse suspected » quand les
  dates n'ont rien a voir), et grille de lecture des trois scenarios.
- Gardes test : section diagnose sans aucun `$dbh->do(` (les selects
  seulement), garde --diagnose/--execute, SHOW CREATE, HEX, alertes.

### mb579 — tools/archive_channel_log_once.pl : archivage ponctuel fidele au bot
- Nouvel outil one-shot qui rejoue EXACTEMENT la tache quotidienne
  `archive_channel_log` (mb569/570/571) avec la conf d'une instance : memes
  cles [mysql], memes bornes (presence 1..3650 j, contenu 0..36500 j, budget
  5000..2000000), meme flux par lots de 5000 (INSERT IGNORE -> VERIFY
  d'identite BINARY champ a champ -> DELETE, plafond strict), CREATE LIKE
  idempotent. Dry-run par defaut (compte les lignes eligibles par politique
  et estime le nombre de runs) ; `--execute` = un run identique au bot ;
  `--execute --loop` = rattrapage complet (runs enchaines avec pause
  `--sleep`, defaut 2 s, jusqu'a epuisement). `--max-per-run` optionnel,
  borne comme le bot. Aucun backtick, mot de passe jamais imprime, repli
  DBD::MariaDB -> DBD::mysql comme les outils freres.
- Test 768 : le bloc VERIFY de l'outil est verifie IDENTIQUE LIGNE A LIGNE
  a celui du bot, bornes et flux presents dans les DEUX fichiers, dry-run
  sans aucune ecriture, --loop refuse sans --execute, VERIFY avant DELETE.

### mb579 — derniere garde pre-commit : resultat archive non contamine
- `channel_log_gather` echoue maintenant proprement si une erreur de fetch
  survient APRES que des lignes d'archive ont deja ete livrees au callback :
  ces lignes partielles ne peuvent pas etre retirees generiquement, donc le
  resultat est marque `tainted`, `live_ok` repasse a 0 et la commande refuse
  d'afficher un historique incomplet. Une panne archive avant toute ligne
  reste best-effort et conserve le resultat du vif.
- `stats` affiche desormais `first seen` meme pour un nick apparu mais encore
  silencieux (`0 message`) et ne le qualifie plus a tort de « not in
  database ».
- Test 768 : fetch archive avant/apres une ligne, contrat fail-closed et
  garde d'affichage de la premiere apparition silencieuse.

### mb578 — semantique « premiere apparition » et contrat LIVE partout
- `when` retrouve son sens (revue pre-commit) : mb577 avait sur-applique le
  filtre public/action et transforme « premiere apparition » en « premier
  message » — un nick ayant rejoint sans parler etait declare absent et
  l'archive de presence ignoree. Deux gathers desormais : premiere
  apparition (tout event_type, scope `all` — un JOIN archive de 2018
  anterieur au premier message fait foi) + compteur de messages
  (public/action, scope `content`) ; un nick apparu sans parler affiche
  « 0 msg(s) ».
- `stats` : msg_count/last_msg restent des messages ; `first seen` redevient
  la premiere TRACE du nick (gather separe, scope `all`, sans filtre).
- Contrat « LIVE KO = echec franc » applique aux 31 gathers : chaque appel
  est capture et verifie (`profil`, `dashboard`, `chronos`, `compat`,
  `seen`, `leaderboard`, et les secondaires de `stats`/`top`) — plus de
  « No history found » ou « no activity » sur une base en panne, plus de
  rang #1 calcule sur une fusion vide. Deux exemptions DOCUMENTEES qui
  degradent proprement : la ligne bonus « your rank » de `top` et le
  suffixe « activity rank » de `wordcount` sont omis sur panne au lieu
  d'inventer un rang.
- Helper : panne du VIF = arret IMMEDIAT de la boucle (l'archive,
  potentiellement une requete historique couteuse, n'est jamais tentee) ;
  les erreurs de fetch (`$sth->err` apres la boucle) sont detectees et
  traitees comme des pannes ; zero ligne reste un succes valide.
- Test 767 (68 assertions) : arret immediat prouve sur fixture (l'archive
  n'apparait pas dans le journal du dbh), erreur de fetch, fusion when
  2018-archive vs 2024-vif, structures when/stats, comptage exhaustif
  gathers vs checks live_ok par sub avec les deux exemptions.
- Test 766 : mbWhen_ctx retiree de l'obligation globale public/action qui
  verrouillait la mauvaise semantique.

### mb577 — securisation du gather archive (revue pre-commit)
- Scope de sources : `channel_log_sources($self, $scope)` ne joint l'archive
  que si elle peut CONTENIR les donnees — `content` exige
  `CHANNEL_LOG_ARCHIVE_CONTENT_DAYS > 0`, `presence` exige
  `PRESENCE_DAYS > 0`, `all` l'une des deux. Conf Undernet (CONTENT=0) :
  les commandes de contenu ne touchent plus l'archive de presence.
- Vide != panne : `channel_log_gather` retourne
  `{ live_ok, sources, executed, ok_sources, rows }` ; zero ligne est un
  succes valide (`m last NickInconnu` repond fonctionnellement, plus jamais
  « Database error ») ; un echec du VIF est un echec franc ; un echec de
  l'archive est logue et le resultat du vif conserve.
- Casse : toutes les cles de fusion par nick sont normalisees `lc`
  (SlaY archive + slay vif = une identite, 300+800=1100) ; casse
  d'affichage memorisee a la premiere rencontre.
- Semantique : les metriques affichees en « msg » (stats, top, streak,
  compare, heatmap, when) filtrent explicitement
  `event_type IN ('public','action')` — la presence ne gonfle plus les
  compteurs de messages.
- Predicats indexables : `DATE(cl.ts) = ...` remplace par des plages
  `ts >= ... AND ts < ...` (top/wordcount/recap periods today/yesterday).
- `wordcount all` streame les textes dans les compteurs (plus d'accumulation
  du corpus entier en memoire) ; le mode plafonne reste borne a
  2 x ROW_LIMIT avant troncature aux plus recents.
- Test comportemental 766 : matrice de scope (dont conf Undernet), vide,
  panne vif, panne archive, fusion de casse, filtres event_type, absence de
  DATE()=, streaming, tous les gather scopes.

### mb576 — compteurs carriere : per-table + fusion Perl (remplace UNION ALL)
- L'analyse (ChatGPT) etait juste : dans une derivee `(vif UNION ALL archive)`,
  MariaDB pousse les WHERE dans les branches mais PAS les ORDER BY/LIMIT — un
  `m last` d'un gros parleur materialisait toutes ses lignes pour en garder
  une, et meme les COUNT materialisaient avant d'agreger. Le modele correct
  etait celui de mb570 (onthisday) : une petite requete PAR TABLE, chaque
  branche sert ses index, la fusion se fait en Perl.
- Nouveaux helpers `Helpers::channel_log_sources` et
  `Helpers::channel_log_gather` (token litteral `__CLSRC__`, best-effort par
  source) ; `channel_log_from` (UNION ALL) supprime.
- Toute la surface carriere refactoree : stats (x4 apres la separation
  first_seen de mb578), top (x3 : total, groupes, compteur cible du caller ;
  le rang reutilise la fusion sans quatrieme requete), streak, leaderboard,
  wordcount (x2),
  last, compat (x2), seen (x2), when, compare, heatmap, profil (x3),
  dashboard (x2), chronos (x4), milestone.
- Fusions plus JUSTES en prime : un nick a cheval vif/archive compte sa somme
  dans les rangs et podiums (l'ancien HAVING/LIMIT par branche le sous-
  estimait) ; les nicks distincts du dashboard passent par un set Perl.
- Fenetres recentes (mood, recap, sparkline dashboard, taux milestone)
  inchangees : vif seul.
- Tests 763/764/765 refondus sur le nouveau contrat (fixture DBH a deux
  sources, garde « aucun UNION ALL hors commentaires »).

### Fixed — complete live+archive lifetime view (mb576, coverage pass)

- Coverage extension (kept, mechanism replaced by the per-table refactor
  above): `top` uses one lifetime source for totals, rows and caller rank;
  `wordcount` ranks against the same population; `compat` reaches
  archived-only users; `seen` fallback, `when`, `compare`, `heatmap`,
  `profil`, and the lifetime sections of `dashboard`, `chronos`, `milestone`
  all see the archive. Explicit recent windows (24h/7d/30d/90d, mood, recap,
  archive ETA) remain live-only by design.
- Reclassified the earlier truthful archive-worker dashboard fix as mb573-B2,
  avoiding two unrelated mb574 labels in the same development batch.

### Added — text readers join the live+archive view (mb575) — mechanism superseded by mb576/mb577

- Sequel to mb574 (counters): three text readers now go through
  Helpers::channel_log_from — wordcount (career sample, ORDER BY primary
  key stays globally coherent since PKs are preserved on move), last (the
  true last message of a long-gone nick lives in the archive) and compat
  (the 5000-message vocabulary sample extends to the archive for
  low-activity nicks). mood intentionally stays live-only (recent
  windows), and the mb574 interpolation guard still holds file-wide.

### Added — career counters see the archive (mb574) — mechanism superseded by mb576/mb577

- Direct sequel to mb570 (which only taught onthisday): the six CAREER
  counter sites now read live + archive through a single
  Helpers::channel_log_from fragment — stats (message count, channel total,
  rank), top (total), streak (distinct days) and the leaderboard msgs
  section. Without a configured archive the fragment is byte-identical to
  the historical 'CHANNEL_LOG' (zero regression); with one, live and annex
  are joined by UNION ALL and MariaDB pushes the predicates into both
  tables so their indexes keep serving. Recent-window features (mood,
  recap) intentionally stay on the live table. Interpolation safety: the
  q{} queries containing REGEXP '$)' sequences are spliced by
  concatenation, never converted to qq{} — a dedicated guard forbids the
  dangerous combination file-wide.

### Fixed — truthful archive dashboard state (mb573-B2)

- Partyline `.status` now shows a currently running archive worker before the
  previous run result; after the first completed run, later workers are no
  longer hidden behind stale history.
- The archive worker now distinguishes a successful zero-row pass from a hard
  SQL/configuration failure. Invalid event policies, missing handles, failed
  table creation, SELECT preparation/execution, INSERT, verification or DELETE
  produce a non-zero worker exit instead of a misleading `exit=0`.

### Added — .status operator dashboard lines (mb573)

- Partyline .status now reports the three queues/background jobs an
  operator actually wonders about, from in-memory state only (same
  non-blocking discipline as the DB/Loop lines — .status never queries
  anything): FloodQ (deferred messages per +AntiFlood channel, with an
  UNARMED flag if a drain timer is missing), AchvQ (pending deferred
  achievement checks), and Archive (disabled / enabled-no-run / worker
  running with pid / last run with exit code, duration and signal). The
  mb571 reap callback now memorizes its last run for this display.

### Added — bilingual horoscope via channel language (mb572)

- The horoscope now speaks the channel's language (Helpers::channel_lang,
  mb563): +LangFR channels keep the historical French reading; every other
  channel (and PMs following a non-fr main.LANG) get a full English version
  — moods, element openers, social/work climates, events, advice, warnings,
  colours, sign names (Aries..Pisces) and elements, translated at display
  time only. Every English pool has exactly the same size as its French
  twin, so one LCG draw lands on the same "card" in both languages, and
  the mb444 deterministic-draw contract is untouched (zodiac boundaries
  remain covered by their own canonical test). Second consumer of
  channel_lang after 8ball.

### Fixed — archive pre-commit safety hardening (mb571)

<!-- mb571-B1: pre-commit archive hardening -->

- The daily CHANNEL_LOG archive now runs in a forked worker with a fresh,
  bounded database handle and IO::Async process reaping, so a multi-million-row
  catch-up cannot freeze IRC. Shutdown terminates and reaps that worker.
- SQL archive batches now enforce MAX_PER_RUN exactly and compare the full row
  identity in live and archive tables before deleting. The legacy monolithic
  purge fails closed whenever the twin archive is configured.
- archive_channel_log.pl freezes executions at a primary-key high-water mark,
  uses indexable month ranges with real-date validation, writes private unique
  gzip files, and preserves the distinction between SQL NULL and a literal \N.
- normalize_channel_log_indexes.pl now skips every projected DROP if any ADD
  failed and exits non-zero, preventing removal of the only usable index.
- Documentation now states the exact scope: onthisday reads live + archive;
  other lifetime commands and achievements still use the live retention window.
- The LUSERS throttle regression test now uses a fixed expired timestamp,
  avoiding full-suite wall-clock and shared-package import flakiness.

### Added — two-tier archive retention + archive-aware onthisday (mb570)

- archive_channel_log gains a second, opt-in retention tier: CONTENT rows
  (public/action/notice/topic/invite by default) older than
  CHANNEL_LOG_ARCHIVE_CONTENT_DAYS also move to the twin archive database.
  Default 0 keeps content in the live table forever; the presence tier
  (7 days) runs unchanged, and MAX_PER_RUN is shared across both tiers.
- onthisday now reads LIVE + ARCHIVE and merges per year (messages summed,
  people maxed, source remembered); the per-year top nick and the era quote
  are fetched from whichever table(s) the year lives in. Best-effort: no
  archive configured, table missing or grants absent => exact historical
  behaviour. Archiving old public no longer amputates channel memory —
  which unlocks the remaining mass action on the Undernet instance.

### Added — daily archive to a queryable twin database + index canon (mb569)

- New daily scheduler task channel_log_archive: rows of the configured
  event types (default: presence — join,quit,mode,part,nick,kick) older
  than PRESENCE_DAYS (default 7) are MOVED into
  <ARCHIVE_DBNAME>.CHANNEL_LOG_ARCHIVE on the same MariaDB server — a real
  queryable table (created automatically, same schema), not a dead dump.
  The predicate is age-based ("older than N days"), so a bot that was
  offline catches up by itself, bounded by MAX_PER_RUN per pass. Replay
  safety: batches of 5000, INSERT IGNORE, then a COUNT verification of the
  whole batch in the archive BEFORE any DELETE — a crash between the two
  steps replays without loss or duplication. Disabled unless
  CHANNEL_LOG_ARCHIVE_DBNAME is set; the bot user needs SELECT,INSERT,
  CREATE on the archive database.
- New tools/normalize_channel_log_indexes.pl (4th of the family): compares
  CHANNEL_LOG's real indexes to the canonical set covering every hot query,
  ADDs what's missing and DROPs prefix-redundant ones (computed on the
  PROJECTED state, so `nick` falls once (nick,event_type) is planned) in
  online DDL — dry-run by default, out-of-canon indexes are flagged for
  review, never dropped automatically. Run it with each instance's conf to
  keep every database identical.
- Fixed analyze_channel_log.pl redundancy detector crash ("Can't use
  string as ARRAY ref"): `for my $a/$b` loop variables shadowed the sort()
  globals. Guard added: no $a/$b loop variables in either index tool.

### Fixed — AntiFlood defers instead of dropping the bot's own output (mb568)

- Root cause of "leaderboard doesn't show everything": on +AntiFlood
  channels, botPrivmsg/botAction silently DROPPED the bot's own messages
  once the flood window filled — any multi-line command (leaderboard,
  horoscope, stats, chronos) lost its tail. Regulated messages are now
  deferred: bounded per-channel queue (30), drained one message every 2s
  by a countdown timer, each deferred send going through the full path
  (NoColors, badword, logging) at real emission time; re-blocked messages
  return to the HEAD of the queue so display order is preserved. A full
  queue drops the newest message with a level-3 log — never silently.
- analyze_channel_log.pl gains a redundant-index detector: any secondary
  index whose columns are a strict prefix of another (exact duplicates
  deduplicated) is reported with a ready online-DDL DROP — never executed.

### Fixed — archive tool: encode UTF-8 before gzip (mb567)

- First real-world run of archive_channel_log.pl on the April selection hit
  "Wide character in IO::Compress::Gzip::write": DBI returns character
  strings and the export pushed them raw into the gzip layer. Every value
  is now encoded to UTF-8 bytes before writing (same wire discipline as
  mb359 for IRC output), proven by a decode/roundtrip test. The
  export-before-delete design did its job during the incident: the run
  stopped in the export phase and nothing was deleted.

### Added — tools/archive_channel_log.pl (mb566)

- Third tool of the CHANNEL_LOG family (measure = query plans, analyze =
  inventory, archive = relief). Investigation mode (--analyze-month) breaks
  a month down by day/event_type/channel/nick in aggregates only. Selection
  filters (--before/--month/--events/--channel, AND-combined) drive a
  DRY-RUN BY DEFAULT; --execute first exports the selected rows to a
  gzip TSV (columns discovered dynamically), verifies exported == selected
  (mismatch aborts with nothing deleted and the archive kept), then deletes
  in bounded batches (--batch 1000..500000, pause between batches) — never
  one monolithic DELETE. --execute without any filter is refused; skipping
  the archive requires an explicit --no-archive. Password never printed,
  message content never displayed. Guard test 757 pins every discipline.

### Added — tools/analyze_channel_log.pl (mb565)

- New read-only ops tool: connects with the bot's own conf ([mysql]
  MAIN_PROG_*, same DSN discipline and driver fallback as
  measure_channel_log.pl) and reports CHANNEL_LOG rows per year (share of
  total, year-over-year delta), last-N-months detail, recent vs lifetime
  daily rate, event_type/channel/nick breakdowns (aggregates only, no
  message content, no password ever printed), physical health (engine,
  sizes, fragmentation, auto_increment headroom with capacity warning),
  present indexes plus verdicts on the three recommended ones (mb558 x2 +
  A4) with ready-to-copy online DDL — never executed by the tool — and a
  whole-database overview (server version, total size, top tables,
  fragmentation flags, collation mix warning). Options: --conf --top
  --months --json --quiet. Guard test 756 pins the read-only and privacy
  disciplines.

### Added — per-channel language chansets (mb563)

- New data-only migration seeds LangFR/LangES chansets. Helpers::channel_lang
  resolves a channel's language: +LangFR forces French, +LangES Spanish (FR
  wins if both), no flag or PM falls back to the global main.LANG (default
  en) — an unmigrated database behaves exactly as before. First consumer:
  the 8ball command; the helper is ready for any other localized command.

### Added — ban/unban script actions + gatekeeper v2 (mb564)

- Scripts may emit ban/unban actions: MODE +b/-b on their ORIGINATING
  channel only, mandatory full nick!user@host mask (wildcards per segment,
  90 bytes max, strict charset), no target field, STATUSMSG-canonicalized
  channel. No other mode change is available to scripts. Applying requires
  ACTION_MODE=apply + ALLOW_IRC=yes + ALLOW_BAN=yes (default no,
  hot-reloadable, fingerprinted). For `ban`, fail-closed self-protection
  is consistent with kick: a literal nick segment equal to the bot's nick is
  refused, an unverifiable identity is refused; a wildcard segment passes
  (undecidable by nick — ALLOW_BAN is the explicit operator gate). `unban`
  remains available as a repair path.
- gatekeeper.pl v2: opt-in ban=yes route config closes the door BEFORE the
  kick (ban nick!*@* then kick); default stays kick-only — zero regression.
  Action-type contracts, plugin known-keys, partyline help, sample.conf,
  README and cookbook updated.

### Fixed — 8ball FR/ES answers were double-encoded (mb562)

- The French and Spanish 8ball answer pools were stored with double-encoded
  UTF-8 (every accent shipped broken on IRC as soon as main.LANG=fr|es).
  Re-encoded once; a new file-wide regression guard (753) now forbids any
  mojibake sequence in every shipped module, so this class of corruption
  cannot silently return.

### Changed — horoscope rework (mb561)

- The horoscope grows up. If the target matches a registered user whose
  USER.birthday is set through the birthday command (canonical DB formats
  MM-DD or YYYY-MM-DD, with legacy dd/mm support), the reading opens with
  their zodiac sign (glyph, name, element)
  and adds an element-tinted opening line plus a "signe complice" of the
  day; without a birthday the same full horoscope is served, simply without
  any sign — never refused, never guessed. New unit-tested
  _horoscope_zodiac_sign covers all 25 boundary dates including 29/02.
- All pools rewritten fully generic: no people, no channels, no project
  files, no internal tooling references. New sections (social climate,
  project climate) join the existing advice/warning/number/colour/luck.
  The mb444 deterministic local-LCG contract is untouched (same seed:
  nick + date), so one nick still gets one stable reading per day.

### Fixed — regression guards caught up with mb559 (mb560)

- Two static guards were stricter than the contracts they encode and failed
  on the legitimate mb559 async worker. The DSN guard now checks "every
  DBI->connect site is timeout-bounded" instead of hard-coding two sites
  (the worker's isolated connection is bounded too, and now counted); the
  duplicate-sub guard now scopes detection by package, accepting the
  Mediabot::Achievements::Worker post-fork overrides while still failing on
  a real duplicate inside one package. Test-only round: no runtime change.

### Fixed — truthful achievement worker outcomes (mb560)

- Successful asynchronous achievement workers now retain the bounded
  `result="ok"` label. The original mb559 whitelist accidentally rewrote that
  valid value to `failed`, which made Grafana's 24-hour worker-failure panel
  count healthy completions. Regression coverage now locks both successful
  and timeout outcome labels.

### Fixed — isolated asynchronous achievement workers (mb559)

- Achievement CHANNEL_LOG aggregations now run in a forked child with a fresh,
  child-only MariaDB connection. The parent event loop only starts one worker,
  reads a bounded JSON result through IO::Async, and applies unlocks after a
  validated success. A 75-second hard timeout, TERM/KILL escalation, bounded
  retries and shutdown cleanup prevent stuck or orphaned work. The inherited
  parent DBI socket is marked InactiveDestroy in the child and is never reused.
- Queue entries remain pending until success; failures rotate with backoff and
  are dropped only after three attempts. Prometheus exposes pending/in-flight
  gauges, worker results, timeouts and bounded-drop reasons. The scheduler runs
  the non-blocking launcher every second, so it can drain promptly without ever
  executing achievement SQL itself.

### Fixed — achievements checks off the PRIVMSG path (mb558)

- Root cause of the 48s "calc" incident (Undernet, 2026-07-23, caught by
  the mb548/550 tracers): the three CHANNEL_LOG aggregations behind the
  message-count, hour-band and polyphony achievements ran synchronously
  inside the PRIVMSG path — the first unthrottled passage on a large
  history table cost tens of seconds. The hot path now only enqueues
  (queue_check: case-insensitive dedup, original casing preserved, bounded
  at 200). MB559 completes this queue foundation with an isolated async
  worker; the Scheduler only launches work and never executes the historical
  scans in the event-loop process. Unlock semantics, thresholds and existing
  throttles remain unchanged, while delivery delay is now observable through
  queue and worker metrics rather than promised to be only a few seconds.
- Each aggregation is now individually timed: slow ones log
  "SLOW ACHIEVEMENT: <check> for <nick>/<chan> took X.XXs" (level 3) and
  every duration feeds mediabot_achievement_check_seconds{check} (fixed
  cardinality); p95-by-check panel added to the overview dashboard.

### Fixed — scheduler metrics startup wiring (mb557)

- The scheduler is now attached to Metrics only after the Scheduler object is
  constructed. The earlier pre-construction call was a silent no-op, so slow
  scheduler logs worked but the new histogram remained empty at runtime.
  The regression contract now verifies ordering, rejects the dead early call,
  and exercises Scheduler::set_metrics directly.

### Added — scheduler tick timing (mb556)

- The named scheduler tasks get the same timing discipline as PRIVMSG, the
  event loop and the partyline — the tracing quadriptych is complete. Both
  execution modes (periodic and calendar) run their callback through one
  shared timed helper: every duration feeds the new
  mediabot_scheduler_tick_seconds{task} histogram (bounded cardinality:
  internal task registry only), any task above one second logs
  "SLOW SCHEDULER: task 'name' took X.XXs" at level 3, and error semantics
  are preserved (a dying callback still logs at level 1, its duration still
  observed). Best-effort metrics via Scheduler::set_metrics (mb550
  pattern); a p95-by-task panel joins the overview dashboard.

### Fixed — kick action scope and wire safety (mb555)

- Kick actions now canonicalize STATUSMSG-decorated channel contexts, reject
  malformed channel targets, enforce the IRC first-character nickname rule,
  bound reasons to 120 UTF-8 bytes, and encode Unicode reasons before the IRC
  write path. Self-kick protection is fail-closed when bot identity cannot be
  checked, and gatekeeper logs a truthful kick request rather than claiming
  that a rejected or failed kick already happened.

### Added — plugin bridge (Perl/Python/Tcl scripts)

- **Kick action** (mb554). Scripts may emit
  {"type": "kick", "nick": "...", "reason": "..."} to eject a nick from
  their ORIGINATING channel. Same fail-closed shape as the topic action:
  no target field accepted, channel context required, nick validated
  against the IRC charset (max 30), reason bounded to 120 with an explicit
  default, and three gates to apply — ACTION_MODE=apply, ALLOW_IRC=yes and
  the dedicated ALLOW_KICK=yes (default no, hot-reloadable, distinct
  refusal errors). The bridge refuses to kick the bot itself and fails
  closed if its current IRC identity cannot be verified at apply time.
- **gatekeeper.pl**, the canonical join-time use: case-insensitive
  substring matching on the joining nick (no user-supplied regex by
  design), total silence on normal joins, an unarmed configuration that
  never kicks. Fifteen examples now ship; cookbook count and citations
  updated under the mb538 guards.

### Fixed — observability truth and non-blocking status (mb553)

- Histogram observations and bucket bounds now accept finite scientific
  notation produced legitimately by Time::HiRes, so very fast runs are no
  longer dropped silently. `.status` reads the DB handle state maintained by
  the canonical five-second health tick instead of performing a synchronous
  ping/reconnect from the partyline. `data.network` is enforced as a reserved
  read-only field, absent without current LUSERS data, and failed LUSERS sends
  no longer advance the refresh throttle or prolong stale snapshots.

### Added — network envelope, status health, partyline tracer (mb552)

- **data.network in the script envelope**: a read-only snapshot (users,
  users_max, channels, servers, operators, age_seconds) built FRESH at
  every payload construction — including deferred timer runs, which see the
  network as it is NOW while their data.config stays the arming-time
  snapshot. Whitelisted fields only, per-field garbage rejection, absent
  entirely until LUSERS data exists; fractional epochs accepted.
- **.status infrastructure lines**: cached DB up/DOWN from the canonical
  five-second health tick (no synchronous partyline probe) and the last
  event-loop stall (or "no stall detected").
- **SLOW PARTYLINE tracer**: the partyline line dispatcher gets the same
  end-to-end timing discipline as the PRIVMSG wrapper — any command above
  one second logs its name and duration at level 3.

### Added — latency histograms (mb551)

- **Histogram metric type** in Mediabot::Metrics: declare(..., 'histogram',
  help, buckets => [...]) with sorted/deduplicated/validated bounds
  (latency defaults when omitted), observe(name, value, labels), and full
  Prometheus exposition (cumulative _bucket lines with le="+Inf", _sum,
  _count, per label set). Backward compatible with the legacy positional
  label-list argument.
- **Two latencies become distributions**: mediabot_privmsg_processing_seconds
  (fed by the PRIVMSG wrapper on every message — the SLOW threshold log is
  unchanged) and mediabot_scriptbridge_run_seconds{origin} (fed from the
  run duration now measured with sub-second precision by ScriptRunner and
  exposed as result->{duration_s}).
- **Dashboards**: p50/p95 PRIVMSG panel on the overview, p95-by-origin panel
  on the scriptbridge dashboard; the dashboard truth contracts learned to
  resolve histogram _bucket/_sum/_count suffixes (trying the full name
  first, since real series can legitimately end in _count).

### Added — DB health metrics and event-loop stall detector (mb550)

- **DB health as Prometheus series**: mediabot_db_up (gauge),
  mediabot_db_reconnects_total{result}, mediabot_db_slow_pings_total —
  emitted from the already-timed ensure_connected path (best-effort
  injection via DB::set_metrics; behavior unchanged without Metrics, and
  a failed reconnect reports db_up=0, consistent with the mb549
  stale-handle fix).
- **Event-loop stall detector**: the 5s periodic tick measures its own
  lateness; any drift beyond 2s logs "event loop stalled ~X.Xs" at level 1,
  increments mediabot_loop_stalls_total and keeps the last stall for
  operator views. Catches synchronous freezes (SQL, DNS, disk) that never
  touch the PRIVMSG path.
- **Overview dashboard**: new Infrastructure row (DB up, reconnects, slow
  pings, loop stalls — compact stats plus two rate panels).

### Fixed/Added — first-command lag diagnosis and hardening (mb548, corrected by mb549)

- **Bounded DB network waits**: both DSN construction sites now set
  mariadb_connect_timeout/read_timeout/write_timeout (mysql.CONNECT_TIMEOUT/
  READ_TIMEOUT/WRITE_TIMEOUT, defaults 5/30/30, bounded). A silently dropped
  idle connection can no longer stall the first command indefinitely.
- **Timed reconnect path**: ensure_connected logs slow pings (level 3, with
  duration) and every reconnect's duration and accurate outcome (level 1),
  clears a dead stale handle before retrying, and never reports success or
  returns the old handle when reconnect fails.
- **Single periodic DB health check**: the existing A4 check on the five-second
  tick remains the canonical keepalive and legacy-dbh synchronization point;
  the diagnostic round does not add a redundant second ping.
- **SLOW PRIVMSG tracer**: end-to-end timing wrapper around the PRIVMSG
  handler; any processing above one second logs its duration and origin at
  level 3 while preserving the caller's scalar/list/void context.

### Fixed — topic action wire safety (mb547)

- Topic actions now canonicalize a STATUSMSG-decorated context to the
  underlying channel, reject malformed context targets before sending, and
  encode Unicode topic text to UTF-8 bytes just like reply/notice actions.
  This prevents invalid TOPIC destinations and wide-character failures in the
  IO::Async write path.

### Changed — plugin bridge examples (mb546)

- **topicreminder.pl learns mode=restore**. With
  `CONFIG_topic=remind_after=900;mode=restore`, the deferred run RE-SETS the
  original topic through the mb545 topic action instead of re-posting it as
  a reply — the canonical demonstration that per-route config can select
  between action types, and that the topic action's triple gate applies to
  deferred runs exactly as to immediate ones (a closed gate leaves the
  dedicated apply error visible in `.scriptdryrun last`, and nothing is
  sent). Default behavior (mode absent or invalid) is unchanged: remind.

### Added — plugin bridge (Perl/Python/Tcl scripts)

- **Topic action** (mb545). Scripts may emit
  `{"type": "topic", "text": "..."}` to change the topic of their
  ORIGINATING channel. Deliberately fail-closed: no `target` field is
  accepted (the channel always comes from the run context, so no
  cross-channel variant exists by construction), a channel context is
  required, the text is capped at 300 characters, and applying it needs
  three gates — `ACTION_MODE=apply`, `ALLOW_IRC=yes` and the dedicated
  `ALLOW_TOPIC=yes` (default no, hot-reloadable, each refusal carrying its
  own distinct error). Dry-run plans the action like any other; the gate is
  visible in `.scriptdryrun status`/`last` and documented in the partyline
  config reference, sample conf, README and cookbook.

### Added — LUSERS visibility (mb544)

- The LUSERS details are now first-class debug material: every numeric that
  yields values logs one level-3 line with its key=value pairs (and the
  periodic/manual refresh requests log at level 3 too), the parsed values
  feed a core cache available even without the Metrics system, and a new
  partyline command `.lusers` shows the network snapshot (users/max/
  channels/servers/operators + age); `.lusers refresh` requests fresh
  numerics immediately and resynchronizes the periodic throttle.

### Added — network stats and overview dashboard (mb543)

- **LUSERS network gauges**: the 251/252/254/265/266 numerics now feed five
  gauges (mediabot_network_users, _users_max, _channels, _servers,
  _operators), parsed defensively in the core (unit-tested) with thin
  eval-guarded handlers. A throttled periodic LUSERS refresh keeps them
  current after the connection burst (main.LUSERS_REFRESH, default 300s,
  bounded 60-3600, 0 disables).
- **Network overview dashboard**
  (contrib/grafana/grafana_mediabot_overview_v1.json), matching the 3.3
  social-preview look: a compact 3-unit-high top stats row (bots up, IRC
  connected, network users/channels, joined channels, 24h messages), network
  graphs, per-channel activity, a top-commands donut, per-target drilldown
  via bot/channel template variables, and clickable Grafana/Prometheus
  logos linking to their sites. Guarded by truth tests (every referenced
  series exists, stats-row compactness asserted).

### Fixed — plugin bridge observability and examples (mb543)

- Prometheus event outcomes now account for incomplete contexts and missing
  runners under `other`; the pending-timer gauge is initialized at zero and
  updated as soon as an expired timer releases its slot, even when the deferred
  run is skipped or fails. The timer metric help now lists only emitted
  outcomes. The Grafana lifecycle panel no longer mixes per-second counter
  rates with an absolute gauge on one axis.
- `topicreminder.pl` now adds a stable digest suffix to its readable timer
  names, preventing sanitized or truncated channel names from sharing a timer
  slot while keeping the 64-character protocol bound.

### Added — plugin bridge (Perl/Python/Tcl scripts)

- **Combined event+timer+config reference** (mb542).
  `examples/topicreminder.pl` re-posts the channel topic after a configurable
  delay (`CONFIG_topic=remind_after=…`, bounded 1-3600, default 300):
  a channel event arms a configured timer whose deferred run rebuilds the
  topic and author from the original envelope — the three arc features in a
  single reference file. It stays silent on the immediate run, arms nothing
  on a cleared topic, and honestly exposes the one-pending-timer-per-name
  semantic (a topic change while a reminder is pending keeps the original
  reminder). Fourteen examples now ship; the cookbook count and citation
  guards were updated accordingly.

### Added — contrib (mb541)

- **Grafana dashboard for the script bridge**
  (`contrib/grafana/grafana_mediabot_scriptbridge_v1.json`): runs by origin
  and result, 24h error ratio, channel-event outcomes with bursts absorbed by
  the anti-storm cooldown, timer lifecycle and the armed-timers gauge.
  Follows the folder conventions (schemaVersion 39, DS_PROMETHEUS variable,
  no hard-coded datasource) and is guarded by truth tests: every PromQL
  series must be declared by the plugin, every declared series must appear
  in a panel, and both READMEs must reference the file.

### Added — plugin bridge (Perl/Python/Tcl scripts)

- **Prometheus metrics for the script bridge** (mb540). Four series under
  mediabot_scriptbridge_*: runs_total{origin,result} (command/event/timer x
  ok/error), events_total{event,outcome} (accepted/cooldown/self/unrouted/
  other, unknown event names aggregated under "invalid" to bound
  cardinality), timers_total{outcome} (armed/delivered/cancelled) and the
  pending_timers gauge. Strictly best-effort: declared and emitted only when
  the bot's Metrics system is present, no new configuration key, and the
  bridge never depends on observability to function (proven by a
  no-metrics regression test).

### Documentation — plugin bridge (mb538)

- **Script cookbook** (`plugins/scripts/COOKBOOK.md`): task-oriented recipes
  distilled from the shipped examples — minimal contract per language, strict
  input parsing, timer lifecycle, event fields by type, misroute silence,
  per-route configuration with mandatory defaults, and the survival rules.
  Guarded by doc-truth tests: every cited example must exist, every shipped
  example must be cited, the written-out count must match reality, and the
  cited technical invariants (event fields, timer-name charset, tighten-only
  configuration) are cross-checked against the actual sources.

### Added — plugin bridge (Perl/Python/Tcl scripts)

- **Hot reload of the plugin configuration** (mb537, hardened by mb539).
  `.scriptdryrun reload` re-reads every plugin key (COMMANDS/ROUTES/SCRIPT,
  ACTION_MODE/ALLOW_IRC/APPLY_REQUIRE_SCOPE, EVENTS/EVENT_COOLDOWN,
  CONFIG_<route>) from the in-memory configuration — use it after
  `.reloadconf`/`.rehash`, which reload the file but never touch plugins —
  and lists what changed. Event listeners are resubscribed when the event
  routes change; counters, cooldown windows and armed timers are deliberately
  kept, and an armed timer always fires with the config snapshot it was armed
  with. The key reads are factored into a single shared helper, so any future
  key is hot-reloadable by construction. The fallback SCRIPT path keeps the
  same single-scalar normalization on register and hot reload, including when
  Config::Simple returns an ARRAY value.

### Added — plugin bridge (Perl/Python/Tcl scripts)

- **Partyline visibility for event cooldown windows** (mb536).
  `.scriptdryrun events` shows the event routes, counters and the
  per-(event, channel) cooldown windows (cooling with remaining time, or
  ready), active windows first, capped at 20 lines with a summary.
  `.scriptdryrun clearevents` resets the cooldown windows only — routes,
  counters and timers are untouched and nothing is ever executed — so an
  operator can unblock a channel after a test or a netsplit instead of
  waiting the window out.

### Added — plugin bridge (Perl/Python/Tcl scripts)

- **Kick event routing** (mb535). The channel-event whitelist gains `kick`:
  the envelope carries the operator (`nick`), the victim (`kicked`) and the
  reason (`message`); events are suppressed whenever the bot is the kicker or
  the victim, and everything else (opt-in EVENTS route, per-channel cooldown,
  channel-scope guard, dry-run/apply gates) is inherited from mb529.
  `examples/kickwatch.pl` ships as the reference moderation-trace script.
  `nick` remains deliberately unsupported (no single channel, out of the
  scope model — see the mb534 handoff).

### Documentation — plugin bridge handoff (mb534)

- Documented that CONFIG_<route> only applies to ROUTES/EVENTS entries: a
  command served by the SCRIPT fallback has no route name, so its CONFIG_ key
  is ignored (README + sample configuration).
- The Timer actions section now points to both reference implementations
  (remind.pl in Perl, countdown.py in Python).

### Added — plugin bridge (Perl/Python/Tcl scripts)

- **Multi-language feature examples** (mb533). The arc's reference examples
  were all Perl; the language x feature matrix is now covered:
  `examples/countdown.py` (Python, routed `pcountdown`) demonstrates timer
  actions plus per-route configuration (`CONFIG_pcountdown=max_seconds=…`,
  tighten-only), and `examples/partwatch.tcl` (Tcl, `EVENTS=part=…`)
  demonstrates channel-event routes and the event-specific `message` field
  (part reason), staying silent on IRC when misrouted. Twelve example scripts ship,
  and the documented sample routes remain covered by the doc-truth guard.

### Fixed — plugin bridge consolidation (mb532)

- The `.scriptdryrun config` partyline reference now documents every key the
  plugin reads: the EVENTS / EVENT_COOLDOWN (mb529) and CONFIG_<route>
  (mb531) blocks were missing since their introduction. A generic test
  contract now cross-checks the reference against the keys actually read by
  the plugin, so a future key cannot be forgotten again.
- `examples/remind.pl` now honors the documented `CONFIG_premind=max_delay=…`
  route configuration (the protocol bounds always win as hard limits; the
  usage reply announces the effective bound).
- `.scriptdryrun status|last` now shows the origin of the last run
  (`command`, `event:<type>` or `timer:<name>`), since mb525/mb529 introduced
  three kinds of runs that were previously indistinguishable.

### Added — plugin bridge (Perl/Python/Tcl scripts)

- **Per-route configuration in the script envelope** (mb531). Every route —
  command or event — can carry its own configuration through one
  CONFIG_<route> key ("key=value; key2=value2", ';' separated so values may
  contain commas). Keys are [A-Za-z0-9_.-] (max 64), values are capped at
  512 chars (oversized pairs are rejected with a log line, never silently
  truncated) and at most 20 keys per route are kept. The validated map is
  injected into the JSON envelope as data.config only when non-empty, and it
  travels with deferred timer runs. data.config is the only structured
  envelope field (one level deep, scalar values); the flat-envelope contract
  of every other field is unchanged. The shipped greet.pl example reads
  config.welcome, and `.scriptdryrun status` lists configured routes.

- **Shipped event reference examples** (mb530). `examples/greet.pl` (join)
  and `examples/topicwatch.pl` (topic) — the two scripts the mb529 sample
  configuration was already referencing — now actually ship. Both stay
  silent on IRC when routed to an unexpected event, and a new test guard
  verifies that every example route documented in the sample configuration
  exists on disk.

- **Channel-event routing** (mb529). The bridge can now route `join`, `part`
  and `topic` channel events to scripts via the new opt-in `EVENTS` key
  (`EVENTS=join=examples/greet.pl, ...`), one script per event and no
  `SCRIPT` fallback. The core emits `channel_<event>_observed` on the
  EventBus from the JOIN/PART/TOPIC handlers (fail-safe, no-op without
  listeners). Event output passes through the same ACTION_MODE / ALLOW_IRC /
  channel-scope guards as command output, and event scripts may arm timers.
  Guardrails: the bot's own events never trigger scripts, and a per-event,
  per-channel cooldown (`EVENT_COOLDOWN`, default 10s, bounded 1-3600)
  counts and ignores join/part bursts (netsplits) instead of forking on each.
  `.scriptdryrun status` exposes the event map, cooldown and counters.

- **Shipped timer reference example** (mb528). `examples/remind.pl`, routed as
  `premind` in the sample configuration, demonstrates the full timer
  lifecycle: validation and confirmation on the command, one pending reminder
  per nick (protocol-safe timer names derived from the nick), delivery on the
  deferred `timer` event with the message rebuilt from the original args, and
  no timer chaining. Documented in the plugin README and sample config.

- **Partyline visibility for script timers** (mb527). `.scriptdryrun timers`
  lists armed timers (name, remaining/total delay, origin
  channel/nick/command, script) plus the runner's pending-slot cap;
  `.scriptdryrun canceltimers` cancels every armed timer and frees its
  pending slot. Cancellation never creates or executes anything.

- **Timer actions are now applied** (mb525). In `ACTION_MODE=apply`, a script
  returning `{ "type": "timer", "name": "...", "delay": N }` re-runs the same
  script after N seconds (1–3600) with the event `timer`; deferred
  reply/notice output passes through the same `ALLOW_IRC` and channel-scope
  guards as direct output. Guardrails: a timer-invoked run can never schedule
  further timers, duplicate pending names are rejected, at most 4 timers may
  be pending at once (runner cap, bounded at 20), and pending timers are
  cancelled when the plugin is unloaded or replaced.

### Fixed

- Script actions can no longer target a different channel than the one the
  command came from (mb524, cross-channel spam/harassment vector).
- Test-suite landmine: three release-contract tests installed dependency
  fallback stubs through named `sub` declarations, which are compiled
  unconditionally and silently overwrote the real
  `IO::Async::Timer::Countdown` methods for every later test in the shared
  harness process (mb525). Fallbacks are now runtime glob assignments.
- Script channel scoping now also recognizes IRC `STATUSMSG` targets such as
  `@#channel` and `%#channel`; these prefixes can no longer bypass the
  cross-channel guard (mb526).
- The mb525 timer test now creates its script fixture in a temporary directory
  instead of relying on `t/tmp_mb*_scripts`, which is intentionally protected
  as generated local state by the commit workflow (mb526).

---

## [3.3] — 2026-07-12

> Released after validation on the development instance and a complete fresh
> Debian 13 installation. Nothing below changes the database schema unless a
> migration is explicitly listed under "Migrations".

### Added — everyday user features

- **`!tell <nick> <message>`** — leave a message that is delivered when the
  recipient next joins or speaks on the channel.
- **Command suggestions** — unknown public commands can offer a guarded
  “Did you mean?” suggestion, with a per-channel `DidYouMean` opt-out.
- **Shared factoids** — `!learn`, `!whatis`, `!forget`, `!factoids`,
  `!factoid`, and the quiet `?keyword` shortcut provide persistent
  channel-scoped knowledge with authorship, hit counts and top/detail views.
- **`!convert`** — offline unit conversion for length, mass, temperature,
  volume, speed and decimal/binary data units.
- **`!stats` achievements** — user statistics can include the number of
  unlocked channel achievements when available.

### Added — channel engagement

- **`!onthisday` / `!otd`** — resurface what happened on the channel on this
  calendar day in past years (per-year stats, most active nick, a
  representative message). Gated by the `OnThisDay` chanset.
- **`!onthisday [MM-DD]`** — target a specific calendar date instead of today
  (e.g. `!onthisday 12-25`). Fully parameterised SQL.
- **Daily "on this day" digest** — opt-in automatic recap posted once a day to
  channels with the `+OnThisDayDigest` chanset, at the hour configured by
  `ONTHISDAY_DIGEST_HOUR` (default 12, set `-1` to disable).
- **`!topquote` / `!halloffame`** — channel hall of fame: the most-recalled
  quotes, ranked by a new `hits` counter that increments whenever a quote is
  shown by id or at random.
- **`!milestone` / `!milestones`** — channel milestones: total messages logged,
  the last round milestone passed, the next one with progress and an ETA based
  on the recent daily rate, plus the channel's logging age.

### Improved

- **`!seen`** — the stored last message is now sanitised for display (IRC
  colour/formatting/control codes stripped, length bounded) and enriched with a
  recent-activity hint (`[N msg in last 24h]`).
- **`!mood`** — beyond sentiment and energy, it now shows a "pulse" line: the
  top talkers of the last 60 minutes and today's busiest hour.
- **Help system** — dispatch/help consistency guard, cleaned-up categories, a
  compact non-truncated welcome screen, working `help <category>`, and detailed
  listings for small categories.
- **URL handling** — richer link previews with details for Apple Music
  (JSON-LD), X/Twitter (tweet text, likes, retweets), Facebook and Instagram;
  sub-second fast paths that avoid launching a browser where possible.
- **`!recap ai`** — the AI summary is now capped in the number of emitted lines
  to prevent flooding, with a truncation notice beyond the cap.

### Fixed
- Release packaging preserves the historical `mediabot_v3-X.Y` archive naming and the canonical `/home/wws/downloads/mediabot` publication path.

- URL compact counter rendered `1000k` instead of `1M` at the 999,999 boundary.
- Facebook/URL previews: hex HTML entities (`&#x…;`) were not decoded, leaking
  raw encoded text; now handled for every URL handler.
- Chromium fallback crashed with SIGTRAP on some hosts; fixed with a unique
  throwaway profile directory and crash-reporter flags.
- Facebook apostrophes truncated link titles (single-quote capture); fixed with
  paired-quote extraction.
- `!milestone` lacked a per-nick cooldown despite scanning the channel log;
  aligned with `!mood` / `!onthisday`.
- `!topquote` / `!halloffame` were mis-categorised in the help index; now grouped
  with the other quote commands.
- `!mood` had no `$dbh` guard and no cooldown; both added.
- Fresh database installation could fail while creating the application user:
  a malformed `sed` expression broke SQL literal escaping even for the generated
  alphanumeric password. SQL quoting is now dependency-free, checked explicitly,
  and verification rollback uses `DROP USER IF EXISTS` with validated literals.

### Migrations

The authoritative complete order for existing databases is maintained in
`install/migrations/README.md`. Do not infer an upgrade plan from this summary
alone; generate and review it against the real instance configuration.

Recent July release migrations, all idempotent and non-destructive:

- `20260706_channel_log_channel_ts.sql` — composite channel/time log index.
- `20260707_channel_report_chanset.sql` — per-channel report gate.
- `20260707_didyoumean_chanset.sql` — command-suggestion gate.
- `20260707_factoid.sql` — persistent shared factoids.
- `20260707_factoids_chanset.sql` — per-channel factoid gate.
- `20260708_onthisday_chanset.sql` — `OnThisDay` chanset.
- `20260708_onthisday_digest_chanset.sql` — `OnThisDayDigest` chanset (opt-in).
- `20260710_quotes_hits.sql` — `QUOTES.hits` recall counter + composite index.

### Hardening / internal

- Boot-time integrity check turns mid-traffic method-resolution failures into a
  clean startup exit.
- bcrypt lazy migration on successful login (no schema change).
- Fresh-install schema and upgrade migrations now carry the same release
  indexes, including `idx_quotes_channel_hits`.
- `check_schema_drift.pl --indexes` compares required reference indexes and
  can generate non-destructive `ADD INDEX` statements for missing indexes.
- `configure` now runs drift checks fail-closed with column types and required
  indexes on the initial check, generated review plan and post-migration check.
- Extensive test suite growth; the offline suite runs green end to end.
- Tag-based public release builder creates deterministic `tar.gz` and `tar.xz`
  archives, includes the tracked `contrib/` and `plugins/` trees, excludes
  local/runtime-only material, and publishes SHA-256 and SHA-512 checksum files.

---

## [3.1] — stable (previous line)

Baseline stable release preceding the 3.2dev development line. See the git
history for the detailed 3.1 series changes.
