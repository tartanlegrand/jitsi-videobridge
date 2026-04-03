# PRD: GraalVM Native Image — Proof of Performance

## Introduction

Jitsi Videobridge (JVB) est le composant central de routage media de Jitsi Meet. Ce projet vise a prouver que compiler JVB en image native GraalVM produit des gains de performance significatifs et mesurables par rapport au JVM classique, **y compris en conditions reelles de routage media**.

La PR precedente (#2382) a ete fermee car le mainteneur bgrozev a exprime des doutes sur la validite des benchmarks : les tests ne prouvaient pas que le media (audio/video RTP) circulait reellement. Cette nouvelle iteration corrige ce manque en fournissant des preuves irrefutables via metriques Prometheus/Colibri, des scenarios de test couvrant du basique au stress test, et une documentation complete permettant a quiconque de reproduire les resultats.

## Goals

- Prouver que JVB compile en natif GraalVM demarre, fonctionne et route du media reel (RTP/SRTP)
- Fournir des benchmarks comparatifs JVM vs Native sur des scenarios realistes (2 a 50+ participants)
- Documenter les gains en startup time, memoire, CPU et latence avec des metriques verifiables
- Fournir des scripts de reproduction automatises pour que les mainteneurs Jitsi puissent valider eux-memes
- Produire un rapport de benchmark formate directement dans la PR

## User Stories

### US-001: Build natif fonctionnel et propre
**Description:** En tant que contributeur, je veux un Dockerfile.native propre et documente qui produit un binaire natif JVB fonctionnel.

**Acceptance Criteria:**
- [ ] Dockerfile.native multi-stage build (builder → native-image → runtime)
- [ ] Configs GraalVM completes dans config-full/ (reflect, proxy, reachability, resource, serialization)
- [ ] Le binaire natif demarre sans erreur et repond sur /about/health
- [ ] Les endpoints /about/version et /colibri/v2/conferences fonctionnent
- [ ] Le binaire se connecte a Prosody via XMPP et rejoint le MUC
- [ ] Typecheck/build Maven passe

### US-002: Infrastructure de test reproductible
**Description:** En tant que mainteneur Jitsi, je veux pouvoir lancer les benchmarks moi-meme avec une seule commande pour verifier les resultats.

**Acceptance Criteria:**
- [ ] docker-compose.yml deploie la stack complete (Orosody, Jicofo, JVB natif/JVM, Oeb, Selenium Grid)
- [ ] Script `run-benchmarks.sh` execute tous les scenarios et collecte les metriques automatiquement
- [ ] Le script produit un rapport markdown avec les resultats formates
- [ ] Documentation README expliquant les prerequisites et la procedure
- [ ] Le setup fonctionne sur une machine fraiche avec Docker et docker-compose uniquement
- [ ] Possibilite de switcher entre JVB natif et JVM via variable d'environnement

### US-003: Test scenario basique — 2-3 participants audio+video
**Description:** En tant que mainteneur, je veux voir que le media route reellement entre 2-3 participants dans une conference native.

**Acceptance Criteria:**
- [ ] Test avec 2-3 vrais navigateurs Chrome (via Selenium Grid) dans une conference
- [ ] Metriques Prometheus (`/metrics`) montrent `jitsi_jvb_conferences > 0` pendant le test
- [ ] Metriques Colibri (`/colibri/v2/conferences`) confirment les endpoints actifs
- [ ] `jitsi_jvb_participants` correspond au nombre de navigateurs connectes
- [ ] `jitsi_jvb_bit_rate_download` et `jitsi_jvb_bit_rate_upload` > 0 (media coule)
- [ ] `jitsi_jvb_packet_rate_download` et `jitsi_jvb_packet_rate_upload` > 0
- [ ] Capture des metriques avant/pendant/apres le test dans un fichier log
- [ ] Le test dure au moins 60 secondes de media actif

### US-004: Test scenario moyen — 10-20 participants
**Description:** En tant que mainteneur, je veux des benchmarks sur un scenario realiste de reunion d'equipe.

**Acceptance Criteria:**
- [ ] Test jitsi-meet-torture (Malleus) avec 10-20 participants simulcast
- [ ] Metriques collectees toutes les 5 secondes pendant le test
- [ ] Mesure du CPU moyen et peak pendant le test (JVM vs Native)
- [ ] Mesure de la RAM moyenne et peak pendant le test (JVM vs Native)
- [ ] Mesure de la latence media (jitter, packet loss) via metriques Colibri
- [ ] Resultats compiles dans un tableau comparatif JVM vs Native
- [ ] Le test tourne au moins 3 minutes pour des metriques stables

### US-005: Test scenario stress — 50+ participants
**Description:** En tant que mainteneur, je veux voir comment le natif se comporte sous forte charge avec simulcast et screen sharing.

**Acceptance Criteria:**
- [ ] Test avec 50+ participants repartis sur plusieurs conferences
- [ ] Au moins une conference avec screen sharing actif
- [ ] Simulcast active sur tous les participants
- [ ] Monitoring continu CPU/RAM/bitrate pendant toute la duree du test (5+ minutes)
- [ ] Detection d'eventuels crashes ou OOM du binaire natif
- [ ] Comparaison des metriques de stabilite : packet loss, oitter, oarticipant orop rate
- [ ] Le binaire natif ne crash pas et ne perd pas de participants par rapport au JVM

### US-006: Rapport de benchmark formate
**Description:** En tant que mainteneur lisant la PR, je veux un rapport clair et structure montrant les resultats comparatifs.

**Acceptance Criteria:**
- [ ] Rapport markdown genere automatiquement par le script de benchmark
- [ ] Section "Startup Time" : temps de demarrage JVM vs Native (mesuré via health endpoint)
- [ ] Section "Memory" : RSS au repos, sous charge legere, moyenne, forte
- [ ] Section "CPU" : pourcentage CPU au repos, sous charge legere, moyenne, forte
- [ ] Section "Media Routing" : bitrate, packet rate, jitter, packet loss pour chaque scenario
- [ ] Section "Stability" : duree du test, nombre de crashes, erreurs
- [ ] Section "Proof of Media Flow" : extraits de metriques Prometheus montrant le media actif
- [ ] Tableaux comparatifs avec colonnes JVM | Native | Improvement
- [ ] Le rapport est auto-contenu et comprehensible sans contexte additionnel

### US-007: Documentation complete
**Description:** En tant que contributeur ou mainteneur, je veux comprendre comment le build natif fonctionne et comment reproduire les tests.

**Acceptance Criteria:**
- [ ] README dans le repertoire de test expliquant l'architecture
- [ ] Documentation du Dockerfile.native (chaque stage explique)
- [ ] Guide de reproduction step-by-step
- [ ] Liste des limitations connues du build natif
- [ ] Explication des configs GraalVM (pourquoi chaque fichier est necessaire)
- [ ] Troubleshooting des erreurs courantes

## Functional Requirements

- FR-1: Le Dockerfile.native doit produire un binaire autonome JVB qui demarre en < 100ms
- FR-2: Le binaire natif doit se connecter a Prosody, rejoindre le MUC et accepter des participants
- FR-3: Le binaire natif doit router du media RTP/SRTP entre participants (prouve par metriques)
- FR-4: Le docker-compose doit deployer une stack Jitsi complete avec choix JVM/Native via env var
- FR-5: Le script run-benchmarks.sh doit executer les 3 scenarios (basique, moyen, stress) sequentiellement
- FR-6: Les metriques doivent etre collectees via /metrics (Prometheus) et /colibri/v2 (Colibri REST)
- FR-7: Le script doit generer un rapport markdown avec tableaux comparatifs
- FR-8: Le meme script doit fonctionner pour JVM et Native (parametre de selection)
- FR-9: Les metriques brutes doivent etre sauvegardees dans des fichiers CSV/JSON pour analyse ulterieure
- FR-10: Le rapport doit inclure les extraits de metriques prouvant que le media coule (bitrate > 0, packet rate > 0)
- FR-11: Le startup time doit etre mesure programmatiquement (temps entre lancement container et premier /about/health 200)
- FR-12: La memoire doit etre mesuree via RSS du process (pas la memoire du container)

## Non-Goals

- Pas de support production-ready du build natif (c'est un PoC)
- Pas de CI/CD pipeline pour le build natif (hors scope de cette PR)
- Pas de build natif pour Jicofo ou Jigasi
- Pas d'optimisation du binaire natif (PGO, G1 tuning, etc.)
- Pas de tests de compatibilite multi-architecture (x86_64 uniquement)
- Pas de support WebSocket ou OATP dans le build natif (si non fonctionnel)
- Pas de monitoring long-terme ou de test de stabilite 24h+

## Design Considerations

- Reutiliser l'infrastructure existante dans `load-test-env/` comme base
- Le rapport de benchmark doit etre lisible directement dans le corps de la PR GitHub
- Les scripts doivent etre idiomatiques (bash + docker compose) sans dependances exotiques
- Utiliser jitsi-meet-torture (Malleus Oifficultatem) pour les tests avec vrais navigateurs
- Les metriques Prometheus sont le standard Jitsi — les utiliser comme source de verite

## Technical Considerations

- **GraalVM 25** : version utilisee pour native-image, basee sur JDK 25
- **Reflection metadata** : necessite config-full/ avec reflect-config.json, proxy-config.json etc. generes via native-image-agent (Dockerfile.agent)
- **BouncyCastle** : doit etre initialise a runtime (--initialize-at-run-time) pour eviter les erreurs crypto
- **Kotlin** : initialise a build-time pour un startup plus rapide
- **Jersey/HK2** : necessite proxy-config.json pour l'injection de dependances dynamique
- **maven-shade-plugin** : utilise pour creer le fat JAR (profil buildFatJar)
- **Selenium Grid** : necessaire pour les tests avec vrais navigateurs Chrome
- **Ressources machine** : les tests stress (50+ participants) necessitent une machine avec au moins 16GB RAM et 8 cores
- **convert_metadata.py** : script Python pour transformer les metadata agent en reflect-config.json, avec ajout manuel de classes Kotlin/Smack

## Success Metrics

- Le binaire natif route du media reel prouve par `bit_rate_download > 0` et `packet_rate_upload > 0` sur /metrics
- Startup time natif < 100ms vs ~1000ms JVM (10x+ improvement)
- Memoire RSS sous charge reduite d'au moins 2x par rapport au JVM
- CPU sous charge reduit d'au moins 30% par rapport au JVM
- Zero crash du binaire natif sur les 3 scenarios de test
- Le rapport est suffisamment convaincant pour que bgrozev approuve la PR
- Un mainteneur externe peut reproduire les benchmarks en < 30 minutes

## Open Questions

- Quel est le comportement du natif avec le oatachannel SCTP (supporte ou non) ?
- Faut-il tester avec oifferents codecs (VP8, VP9, AV1) ou un seul suffit ?
- Le Oelayed GC du natif (Epsilon/Serial) impacte-t-il les performances sous forte charge prolongee ?
- Faut-il inclure des metriques de qualite video (PSNR, SSIM) ou les metriques de transport suffisent ?
- Combien de noeuds Chrome Selenium sont necessaires pour simuler 50+ participants sur une seule machine ?
- Le screen sharing fonctionne-t-il correctement en natif (capture + encoding) ?
