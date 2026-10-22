# Graphics-playtest — 22 oktober 2026, R36–R41

Dit daglog volgt op [het nachtlog](graphics-night-2026-10-21.md) en het
[performanceoverzicht](graphics-performance.md); historische resultaten blijven intact.
**Vier spelers, native 3840×2160 en 120 FPS / 8,33 ms zijn nog niet aangetoond.**
Auto/upscaling behoudt 4K-uitvoer, maar is geen native 4K-rendering.
R40 is niet vrijgegeven; R41-validatie en pakketcontroles slagen. Native/auto-metingen
zijn beschikbaar; bewegings- en weerbeeldreviews lopen nog.

Artefactnamen hieronder zijn relatief aan `C:\dev\perf\`:
`OUT38 = sideways-playtest-r38-20261022`, `OUT39 = sideways-playtest-r39-20261022`,
`OUT40 = sideways-playtest-r40-20261022`, `OUT41 = sideways-playtest-r41-20261022`,
`NIGHT = sideways-night-20261021`. Basis: Godot 4.5.2 Forward+/Vulkan,
120 Hz/vier substeps; sequentiële GPU-runs.

## R36–R38 — feedback tijdens het spelen

De rechterstick kiest per speler een richting rond de auto: boven = normale chase,
rechts = camera aan de linkerflank, onder = vóór de auto, links = rechterflank.
Joypads en GameNight delen deadzone, hoekinterpolatie/terugkeer en world avoidance.
Finish gebruikt hold in plaats van remdruk die bij stilstand automatisch achteruit kon
kiezen; geen teleport of wijziging vóór de finish. R38 player-controls: 296 controles.
Wegdetail kreeg een world-XZ-normalbasis en aparte wegrichting; bermen sluiten spleten
met open brugzijden en ongewijzigde gereden colliderfaces. Sporen volgen de laterale positie.
Rotsen en alle gegenereerde stammen kregen echte colliders: de botroute mag daardoor
bewust veranderen. WheelFX bedient vier contacten met dezelfde zes emitters/budgetten;
geboorteparameters blijven bij bestaande deeltjes na een oppervlakwissel.
De vijf-oppervlakkenfixture gebruikt synthetische contacten; pixels zijn beoordeeld:
`NIGHT/wheel-fx-gpu-fixture-r37/runs/20261022T103642955494Z`.
R38-import, regressies, lifecycle en echte grasplaatsing zijn gecontroleerd. Nieuwe
simulatiehash `179ef913b38fc2d3`; de afwijking van de oude oracle is geregistreerd.

## R38-export — vergelijking binnen dezelfde sessie

`OUT38/release-abba-20261022T103801Z`: echte R35/R38-executables, native 4K/vier views,
1200 gemeten frames na 240 warmup, fixed120, seed4242/300 m, clear, vegetation auto,
rivals0. Werkelijke viewports: 1916×1076, schaal1.

| Volgorde | Build | Mean ms | p95 ms | p99 ms |
| --- | --- | ---: | ---: | ---: |
| A1 | R35 | 9,33485 | 11,464 | 12,964 |
| B1 | R38 | 9,50810 | 11,567 | 13,093 |
| B2 | R38 | 9,78671 | 11,971 | 13,278 |
| A2 | R35 | 9,50508 | 11,819 | 13,059 |

Gemiddelde frametijd: 9,41997 → 9,64741 ms, **2,41% hoger**, geen snelheidswinst.
Dit vergelijkt complete pakketten met veranderde colliders/route, geen geïsoleerde
featurekosten of typische gameplay-FPS. R35 draait overdag ook veel sneller dan 's nachts:
absolute dag-/nachttijden bewijzen geen buildwinst. 120 FPS blijft open.

## R39 — oppervlakken en AA

Gravel/loose/grass/dirt/water behouden hun IDs; asphalt5 en mud6 delen descriptoren
voor uiterlijk, grip, AI en WheelFX. Water blijft voorgaan. Headless reparaties betroffen
een echte testtypefout, expliciete tyre-materiaaldefaults en verouderde successmarkers.
Oppervlak- en bandentest slagen, inclusief 2940 bandentests. Sim45000 herhaalt exact
`b6cd34ced008b6b2` met bewust gewijzigde grip: `OUT39/r39-repair-review.json`.

De huidige standaard is **auto + spatial**. Spatial = native FXAA of FSR1+FXAA onder
100%; temporal = native TAA of FSR2 onder 100%. MSAA blijft uit. De gematchte R38-reeks
van 64 frames toont minder kroonvegen en scherpere auto-/wieldetails met FXAA, maar meer
korrel/kartels. De zeer lange spiegeltrail is niet overtuigend gereproduceerd:
`NIGHT/r37-car-edge-fxaa-motion-120-4/runs/20261022T103225679145Z`.
R39's drie AA-reeksen bevestigen native-TAA-kroonsmeer, spatial75-korrel en temporal75-
raster/stipple in gras. Geen algemene oplossing voor flikkering of trails geclaimd.

## Gras, bomen en grondlicht — geïntegreerd, eindkwalificatie nog open

Gras gebruikt één lineaire coverage-factor, gedeelde ringovergangen en vaste
UV/world-root-maskerfase in plaats van schermpixelruis; geometrie, hoogte en budget blijven.
Alle 96 kandidaatframes matchen 96 baselineframes met exact vier auto-/cameratrajecten:
`NIGHT/r39-vegetation-aa-motion-120-4/runs/20261022T112150247763Z`.
Grasuitsneden zijn voller/coherenter zonder hoogteverandering; FSR2-raster/TAA-vegen blijven.
Bewijs: 0,258 s clear4/low-grass, geen volledige route-/weergate of kostenclaim.
Meer doorgelaten fragmenten kunnen overdraw verhogen. De photo-grass-test behoudt
mesh/UV/mip/plaatsingschecks en controleert beide coverage-grenzen.

De baker kreeg een typebewuste Color-fallback voor ontbrekende tint; expliciete waarden
blijven behouden. `OUT39/tree-tint-trial/runs/20261022T113301348313Z`: 28 checks,
twee byte-identieke atlasparen, normals/binaire alpha onveranderd. Vier onbelichte MID/FAR-
beelden tonen betere kleurmatching met identieke MID-pixels (`unlit-runs/20261022T114401237478Z`).
Alle 40 railframes met oude camerageschiedenis zijn beoordeeld
(`rail-runs/20261022T115648499245Z`): begrensde kleurcorrectie geaccepteerd;
alpha-/hoekafhankelijke coverageverschillen blijven.

De 18 canopybeelden ondersteunen constante 0,75-verdonkering voor weg/terrein plus
half min/product in de gedeelde helper, zonder extra texturefetch.
`OUT39/canopy-controlled/review-111652.txt`: vlakke patches, echte car-casters en
vastgezette regentijd, geen volledige bos-/wet-releaseacceptatie.
Natte wegfacetten blijven onopgelost. Puddle-normal/ruwheid, terrain-overlap/-schaduw en
het fragment-Gaussian-maskerexperiment leverden geen geaccepteerde oplossing; de laatste
productieproef is exact teruggedraaid. Ook bestaande mud-overlaycoverage bij `dirt=0`
blijft open: de niet met dirt vermenigvuldigde caked-term kan onderaan al alpha geven.
Dit is een codebevinding, geen gemeten oorzaak van de wegfacetten.

## R40 — weer, stage, laden en controller

Live weerkeuze heft CLI-override op en past Look/wetness/lichten direct toe; random houdt
huidig weer tot de volgende stage. AI's herplannen grip zonder extra RNG/pursuitstateverlies.
Nieuwe stage-layout: begrensde heading, vloeiende bochten en meer afwisseling.
`OUT40/new-contracts.json`: import, 195 weatherchecks en 402938 layoutchecks geslaagd.
Loading: `OUT39/loading-gpu/run-20261022T114220001681Z` bewijst 1356 getekende
loadingframes, bevroren raceclock/tick, drie volledige builds en nieuwste roster na
dispose/reprepare. Zichtbare balk/tekst/teller; offline SDK-handlers, geen transporttest.

Auto gebruikt één schaal voor de totale uitvoer: circa75% op 4K, native op1080p,
begrensd50–100%. GPU-only filtering/hysterese/cooldowns; manual blijft vast.
Loading/menu/pause/headless/screenshots en gewone benchmarks adapteren niet.
Root+view-timestamps zijn asynchrone laatste waarden zonder frame-ID en missen GPU-werk
buiten de viewports; geen volledige GPU-frametijd of FPS-garantie.
`OUT39/dynamic-resolution-gpu/runs/20261022T115311787834Z` met expliciete adaptive-flag:
1440 frames, 1438 geldige root+vier-metingen, 244 samples; echte75→85%-beslissing bij
tick452, daarna stabiel. 4K-uitvoer/FSR1+FXAA, 107,69 instrumented FPS,
9,28560 ms mean / 11,524 p95 / 12,813 p99: **geen eindbenchmark of 120 FPS-bewijs**.
ObjectDB/één-resource-afsluitmelding behoudt ruwe FAIL; aparte adjudicatie bevestigt
alleen controllerfeeding/beslissingen, geen schone exit.

R40's volledige suite behield de oude handling en twee identieke nieuwe Sim45000-
resultaten: `f31f454d8d6d2cb9` (4 stages, 6 finishes, 221 shifts, 8 recoveries).
De oorspronkelijke schaduwfixture faalde; een dummy-renderer-testcorrectie slaagde
headless, maar **echte GPU custom-data-centre/end/bufferchecks bleven falen**.
Eerdere instance uniforms hadden de rendererpool uitgeput. Alle fouten zijn bewaard;
R40 is niet geëxporteerd of als geslaagde release aangemerkt.

## R41 — merge en volledige validatie

Incoming tot `10b1f75` brengt TreeSets, globale windtijd en fernschaduwen-uit.
Near/mid/shadow gebruiken per camera drie varianten × drie MultiMesh-nodes, private
viewlagen en spare-buffers die na twee getekende frames wisselen. Resets/viewwijzigingen
vullen direct opnieuw. Far-impostors blijven aparte blokken; negen nodes is geen claim
van negen totale renderdraws. Nieuwe schaduwfade gebruikt de oorsprong per boom,
zonder het afgewezen block-instance-uniform/custom-data-pad.
Hergebruikte slots erfden physics-interpolatie en stelden echte GPU-buffers uit.
Expliciet OFF voor die statische sets verhelpt dit zonder assertions te verzwakken:
`OUT41/preflight-tree-sets-gpu-interpolation-off.log`, 414 GPU/lifecyclechecks geslaagd.
Gedeelde windtijd bewijst op zichzelf geen correcte motion vectors of stabieler AA.

De volledige bevroren R41-suite slaagt: import/scriptcontrole, functionele tests,
exacte oude handling, beide Sim45000-runs exact `f31f454d8d6d2cb9`, SDK-lifecycle en
verse echte GPU-checks voor gras, forest-shadow en TreeSets. `inputs_changed=[]`;
bewijs: `OUT41/r41-final-summary.json` en `r41-final-evidence.json`.
Bestaande exact begrensde headless/autoload-diagnostiek blijft in de logs; GPU-gates
hebben geen nieuwe error-/resource-uitzondering. De echte export slaagt ook voor embedded
licenties, texture-/mipmap-/shader-/materiaalbindings en GameNight-lifecycle, zonder bronpad:
`OUT41/release-runs/20261022T125555378941Z/summary.json`.
Build: `C:\dev\sideways-playtest-r41-20261022\build\Sideways-r41.exe`, 328079056 bytes,
SHA256 `5b4a1b7397eab3772d4f77ed1a025e55a1c70250600e2926f9b3b4fa874f4b3f`.
De bron/staging-adjudicatie rekent alle 348 gevalideerde inputs af: 346 bytegelijke
paren plus alleen de historische standalone `tools/audit.gd` en `tools/check_mips.gd`,
uitgesloten door `tools/*`. Raw parity blijft bewaard; geen runtime/test-uitzondering.

## R41 — echte exportmetingen, begrensde conclusie

`OUT41/release-performance-20261022T130437321559Z/results.json`: literal executable,
vier auto's/views, native 4K-uitvoer, spatial-AA, seed4242/300 m, 120/4, fixed120,
1200 frames na 240 warmup. Native heeft schaal1/FXAA; auto gebruikt FSR1+FXAA.

| Volgorde | Weer / schaalkeuze | FPS | Mean ms | p95 ms | p99 ms |
| --- | --- | ---: | ---: | ---: | ---: |
| A1 | Clear native100 | 110,53 | 9,04762 | 11,263 | 13,842 |
| B1 | Clear auto | 98,41 | 10,16157 | 13,298 | 15,086 |
| B2 | Clear auto | 76,54 | 13,06548 | 16,227 | 17,609 |
| A2 | Clear native100 | 115,47 | 8,65993 | 10,595 | 11,864 |
| Los | Wet auto | 118,16 | 8,46334 | 10,187 | 11,117 |

Native mean gemiddeld 8,85378 ms (circa113 FPS), auto 11,61352 ms: in deze twee paren
31,17% méér frametijd. Sterke auto-variatie verhindert een algemene oorzaak-/kostenclaim;
geen bewezen auto-winst. Alle autoruns gaan één keer75→85% op4,61–4,85 ms viewport-GPU,
zonder terugschakelen. CPU-grens, FSR-overhead of andere variatie zijn nog hypotheses.
Wet is een ongepaarde smoke-run. Alle runs melden dezelfde exact begrensde oude
één-resource-exitdiagnostiek expliciet; geen schone afsluiting geclaimd.
Een eerdere native4-preflight van120,15 FPS is geen extra ABBA-resultaat; p95 bleef10,13 ms.
Native1 bij900 m was veel trager (34–46 periodieke FPS) met ongeveer hetzelfde aantal
scene-nodes. Daarom volgen afgebakende CPU-profielen; totale collider-nodecount bewijst
geen oorzaak. Fixed120 bepaalt simulatietempo, niet normale uncapped gameplaykosten.
Stabiele120 FPS, brede wet/motion-acceptatie en opgelost vegetatieflicker blijven open.
