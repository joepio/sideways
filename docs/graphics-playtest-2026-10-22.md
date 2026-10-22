# Graphics-playtest â€” 22 oktober 2026, R36â€“R40

Dit daglog volgt op [het nachtlog](graphics-night-2026-10-21.md) en het
[performanceoverzicht](graphics-performance.md); die historische resultaten blijven intact.
**Vier spelers, native 3840Ã—2160 en 120 FPS / 8,33 ms zijn nog niet aangetoond.**
Auto/upscaling behoudt 4K-uitvoer, maar is geen native 4K-rendering.
De definitieve samengestelde R40-validatie, export en eindmeting zijn nog open.

Artefactnamen hieronder zijn relatief aan `C:\dev\perf\`:
`OUT38 = sideways-playtest-r38-20261022`, `OUT39 = sideways-playtest-r39-20261022`,
`OUT40 = sideways-playtest-r40-20261022`, `NIGHT = sideways-night-20261021`.
Basis: Godot 4.5.2 Forward+/Vulkan, 120 Hz/vier substeps; sequentiële GPU-runs.

## R36â€“R38 â€” feedback tijdens het spelen

De rechterstick bestuurt per speler een richting rond de auto: boven = normale chase,
rechts = camera aan de linkerflank, onder = vÃ³Ã³r de auto, links = rechterflank.
Joypads en `GameNight.stick(frame, 1)` delen deadzone, hoekinterpolatie/terugkeer en world avoidance.
Na de finish gebruikt de auto hold in plaats van remdruk die bij stilstand automatisch
achteruit kon kiezen. De auto stopt zonder teleport; gedrag vÃ³Ã³r de finish blijft gelijk.
`OUT38/r38-headless-player-controls.log`: 296 controles, inclusief terugkeer/reset en finish.

Wegdetail kreeg een correcte world-XZ-normalbasis en apart meegevoerde wegrichting;
bermen sluiten zichtbare spleten, met open brugzijden en ongewijzigde gereden colliderfaces.
Bandensporen volgen de laterale positie. Rotsen en alle gegenereerde boomstammen kregen
werkelijke colliders; daardoor mag de botroute bewust afwijken van de oude simulatie.
WheelFX bedient vier contacten met dezelfde zes emitters/budgetten; geboorteparameters
blijven bij bestaande deeltjes bewaard na een oppervlakwissel. De GPU-fixture voor
vijf oude oppervlakken is visueel beoordeeld, maar gebruikt synthetische contacten.
Bewijs: `NIGHT/wheel-fx-gpu-fixture-r37/runs/20261022T103642955494Z`.
R38-import, gerichte regressies, lifecycle en echte grasplaatsing zijn gecontroleerd;
de oude exacte simulatie-oracle faalt zichtbaar, met nieuwe hash `179ef913b38fc2d3`.

## R38-export â€” werkelijke vergelijking binnen dezelfde sessie

`OUT38/release-abba-20261022T103801Z` gebruikt de echte R35/R38-executables,
native 4K/vier views, 1200 gemeten frames na 240 warmup, fixed120, seed 4242/300 m,
clear, vegetation auto en rivals0. Werkelijke viewportmaten zijn 1916Ã—1076 op schaal 1.

| Volgorde | Build | Mean ms | p95 ms | p99 ms |
| --- | --- | ---: | ---: | ---: |
| A1 | R35 | 9,33485 | 11,464 | 12,964 |
| B1 | R38 | 9,50810 | 11,567 | 13,093 |
| B2 | R38 | 9,78671 | 11,971 | 13,278 |
| A2 | R35 | 9,50508 | 11,819 | 13,059 |

Gemiddelde frametijd: R35 9,41997 â†’ R38 9,64741 ms, **2,41% hoger**, geen snelheidswinst.
Dit vergelijkt complete pakketten; nieuwe colliders veranderen de route. Geen geÃ¯soleerde
featurekosten of typische gameplay-FPS. Dezelfde R35 draait nu veel sneller dan 's nachts:
vergelijk de absolute dag-/nachttijden niet als winst door een nieuwe build. 120 FPS blijft open.

## R39 â€” oppervlakken, AA en herstel van controles

Gravel/loose/grass/dirt/water behouden hun IDs; asphalt 5 en mud 6 voegen gedeelde
wegdescriptoren voor uiterlijk, grip, AI-planning en WheelFX toe. Water blijft voorgaan.
De eerste headless ronde vond een echte typefout in de oppervlaktest, ontbrekende expliciete
materiaaldefaults voor tyre-introspectie en verouderde successmarkers. Reparaties zijn apart
herhaald: oppervlak- en bandentest slagen; 2940 bandentests. De 45.000-ticksimulatie
herhaalt exact hash `b6cd34ced008b6b2`, met bewust gewijzigde oppervlakgrip. De afwijking
van de oude oracle blijft geregistreerd in `OUT39/r39-repair-review.json`.

De AA-keuze is expliciet: spatial = native FXAA of FSR1+FXAA onder 100%; temporal =
native TAA of FSR2 onder 100%. MSAA blijft uit. De gematchte R38-reeks van 64 frames toont
minder brede kroonvegen en scherpere auto-/wieldetails met FXAA, maar meer korrel/kartels.
De zeer lange spiegeltrail is niet overtuigend gereproduceerd in de zijwaartse orbit.
`NIGHT/r37-car-edge-fxaa-motion-120-4/runs/20261022T103225679145Z` bevat de begrensde review.
R39's drie AA-reeksen bevestigen: native TAA smeert kronen; spatial 75% is korrelig;
temporal 75% behoudt raster/stipple in gras. Geen algemene oplossing voor flikkering geclaimd.

## R40-kandidaten â€” gras, bomen en grondlicht

Gras gebruikt Ã©Ã©n lineaire coverage-factor, gedeelde volledige ringovergangen en een vaste
UV/world-root-maskerfase in plaats van schermpixelruis; geometrie, hoogte en instancebudget
blijven gelijk. Alle 96 kandidaatframes zijn tegen 96 baselineframes gepaard, met exact dezelfde
vier auto-/cameratrajecten: `NIGHT/r39-vegetation-aa-motion-120-4/runs/20261022T112150247763Z`.
De bekeken grasuitsneden zijn voller/coherenter, zonder hoogteverandering; FSR2-raster en
TAA-vegen blijven. Slechts 0,258 s clear4/low-grass; 1p, wet, volledige beelden en kosten blijven
een aparte gate. De vier bestanden zijn integratiekandidaat, geen claim dat pop/flicker opgelost is.
`photo_grass.gd` behoudt mesh/UV/mip/plaatsingschecks en controleert nu beide coverage-grenzen.

De baker gebruikte bij NIL-tint een ruwe Vector3; nabije `source_color`-tint wordt lineair verwerkt.
De nieuwe Color-fallback behoudt expliciete waarden.
`OUT39/tree-tint-trial/runs/20261022T113301348313Z`: 28 semantische checks en twee
byte-identieke atlasparen; normals en binaire alpha onveranderd. Vier echte onbelichte
MID/FAR-beelden tonen betere kleuraansluiting, met identieke MID-controlepixels:
`unlit-runs/20261022T114401237478Z`. Dezelfde 40-frame rail is daarna opgenomen met exacte
oude camerageschiedenis (`rail-runs/20261022T115648499245Z`). Review van alle 40 frames
accepteert de begrensde kleurcorrectie; alpha/angular-coverageverschillen blijven zichtbaar.

De 18 gecontroleerde canopybeelden tonen dat afstandsafhankelijke verdonkering te sterk was
Ã©n bestaande canopy lokale autoschaduw kon verbergen. Kandidaat: constante 0,75 voor weg/terrein
plus half min/product zichtbaarheid in de gedeelde helper; geen extra texturefetch.
`OUT39/canopy-controlled/review-111652.txt` begrenst dit bewijs: vlakke patches, echte
car-casters, vastgezette regentijd, geen volledige bos-/wet-releaseacceptatie.
Wegovergangen krijgen een smalle dressingband rond de echte gripgrens; natte facetten en
boomschaduw-overgangen blijven afzonderlijke diagnoses, geen blind toegepaste normalfix.

## R40 â€” weer, stage, laden en automatische resolutie

Een live weerkeuze heft de CLI-override op en past Look/wetness/lichten direct toe; random
houdt het huidige weer tot de volgende stage. Bestaande AI's herplannen grip zonder extra RNG
of verlies van pursuitstate. De stage-layout gebruikt begrensde heading, vloeiende bochten en
meer afwisseling; deze nieuwe route vereist expliciete nieuwe simulatiebeoordeling.
`OUT40/new-contracts.json`: import, 195 weatherchecks en 402938 layoutchecks geslaagd.

Werkelijke loadingprogress is bewezen in `OUT39/loading-gpu/run-20261022T114220001681Z`:
1356 getekende loadingframes, stilstaande raceclock/tick, drie volledige builds, zichtbare
tekst/balk/teller en nieuwste roster na dispose/reprepare. Offline SDK-handlers, geen transporttest; het readybeeld bewijst geen camera/beeldkwaliteit.

Auto is nu de gevraagde standaard, 50â€“100%, uniforme schaal op de totale uitvoer, GPU-only
filtering/hysterese/cooldowns; manual blijft vast. Menu/loading/pause/gewone benchmarks
adapteren niet. `OUT39/dynamic-resolution-gpu/runs/20261022T115311787834Z` gebruikt expliciet
`--adaptive-render-scale`: 1440 frames, 1438 geldige root+vier-GPU-metingen, 244 samples.
Bij tick 452 verhoogt de echte controller75â†’85% wegens GPU-headroom; daarna stabiel.
Werkelijk 4K-uitvoer/FSR1+FXAA, 107,69 instrumented FPS, 9,28560 ms mean, 11,524 p95, 12,813 p99.
Dit is variabele resolutie met observerkosten, **geen eindbenchmark of 120 FPS-bewijs**.
De oude ObjectDB/Ã©Ã©n-resource-afsluitmelding laat de ruwe status failed; afzonderlijke
`integration-adjudication.json` bevestigt alleen feeding/decisions, niet een schone exit.

Nog open: volledige samengestelde R40-controles en expliciete simulatiereview, shader/GPU-
weer- en bewegingsgates, nieuwe export met resourcecontrole en eerlijke native/auto-eindmetingen.
