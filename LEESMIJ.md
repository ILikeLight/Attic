# Attic

Emulator-app voor iPhone, versie 0.5 (fase 4; `MARKETING_VERSION` en `CURRENT_PROJECT_VERSION` in het Xcode-project, Instellingen › Versie leest ze uit de app). SwiftUI-interface volgens het klikbare ontwerp, met tien emulatiekernen via libretro: mGBA, Nestopia UE, bsnes, melonDS, PCSX ReARMed, Mupen64Plus-Next, Dolphin, Flycast, Azahar en PPSSPP. Titels komen uit een ingebouwde spellendatabase (OpenVGDB), hoesjes van GameTDB en libretro.

## Wat werkt

- **Bibliotheek**: raster of lijst, kaartjes in drie groottes (klein, normaal, groot), zoeken, filters per systeem, "Verder spelen" met een screenshot van je auto-save, en een NIEUW-label bij nieuwe spellen.
- **Spellen toevoegen**: via de Bestanden-app, via "Open in Attic" vanuit andere apps, of door een map in de gaten te houden (Bestanden › Attic). Spellen die uit meer bestanden bestaan (cue/bin) zet je daar als zip neer.
- **Uitpakken**: .zip (ook zip64) en .7z (LZMA, LZMA2, PPMd en BCJ-filters). Grote bestanden worden in stukjes uitgepakt, dus een Wii-schijf van 4,7 GB past ook. Na het uitpakken wordt het archief opgeruimd; dat kun je uitzetten.
- **Toevoegscherm**: hoesje en titel "decoderen" terwijl het spel uitpakt: lichte tekens ( . : ) worden dichtere ( # % @ ) in de kleuren van het hoesje en klikken vanuit het midden vast, mee met de voortgang; aan het eind komt het echte hoesje erdoor (`Views/DecodeReveal.swift`, naar de decode-stijl van ascii-reveal). Heeft het archief een officiële No-Intro- of Redump-naam, dan zoekt de app het spel al vóór het uitpakken op in de database en haalt hij het hoesje meteen op (`ImportPipeline.expectedGame`, `GameDatabase.entry(named:)`); klopt de naam, dan gebruikt stap 3 dat hoesje en wordt het niet nog eens gedownload. Anders zoeken de letters tot het spel herkend is. Met Verminderde beweging aan is het een gewone overgang.
- **Herkennen aan de inhoud**: spelcodes en spelkoppen van GBA, GB/GBC, DS, 3DS, Wii en GameCube (ook WBFS, RVZ, WIA en CISO), N64, NES, SNES, Mega Drive, PSP (PARAM.SFO op UMD-images en in EBOOTs), PS1 (cue/bin, CHD, en losse PlayStation-programma's; de spelcode uit SYSTEM.CNF, zoals SCUS-94900) en Dreamcast (cue/bin, GDI en CHD; de spelcode uit de opstartkop van de schijf, zoals MK-5100650). Een rommelige bestandsnaam zoals `smg2.iso` krijgt zo toch de goede titel. Bij cartridges zonder volledige titel in de spelkop wordt de bestandsnaam opgeschoond, bijvoorbeeld "Legend of Zelda, The - … (Europe)" → "The Legend of Zelda: …". DS-homebrew zonder Nintendo-logo wordt herkend aan de controlesom van de spelkop.
- **Titels en hoesjes**:
  - De app zoekt elk spel op in een ingebouwde database met 55.290 spellen uit de libretro-database (No-Intro, Redump en GameTDB; CC BY-SA 4.0). Cartridges vindt hij aan de checksum zoals No-Intro die telt: zonder iNES- of kopieerkop, en N64 in big-endian volgorde (dus .v64 en .n64 ook); lukt dat niet, dan aan de spelcode in de kop. DS- en 3DS-spellen en schijven vindt hij aan hun spelcode (GameCube en Wii aan de eerste vier tekens: GW7E69 is GW7E), en bestanden met een No-Intro- of Redump-naam ("Crash Bandicoot (USA).chd") aan die naam. Gevonden spellen krijgen de officiële titel, het jaar en de regio.
  - Met "Hoesjes automatisch ophalen" aan (standaard) haalt de app het hoesje op. DS, 3DS, GameCube en Wii komen van GameTDB op spelcode, de rest van de libretro-thumbnails op de No-Intro- of Redump-naam.
  - Het hoesje wordt verkleind tot hoogstens 600 pixels en als JPEG op de iPhone bewaard. Hoesjes van elke vorm staan heel op het kaartje, op hun eigen gemiddelde kleur.
  - Spellen die al in de bibliotheek stonden, worden bij het openen van de app één voor één bijgewerkt. Geen internet? Dan probeert de app het later opnieuw; een hoesje dat niet bestaat, zoekt hij na een maand nog eens.
  - Op de spelpagina staat onder "Herkenning" waar titel en hoes vandaan komen.
- **Spelen**:

  | Systeem | Emulator |
  |---|---|
  | Game Boy, Game Boy Color, Game Boy Advance | mGBA |
  | NES | Nestopia UE |
  | Super Nintendo | bsnes |
  | Nintendo 64 | Mupen64Plus-Next |
  | GameCube, Wii | Dolphin |
  | Dreamcast | Flycast |
  | Nintendo 3DS | Azahar |
  | PSP | PPSSPP |
  | Nintendo DS | melonDS |
  | PlayStation | PCSX ReARMed |

  Bij alle systemen:
  - beeld via Metal (scherpe pixels zonder ongelijke breedtes);
  - geluid via AVAudioEngine; het mengt met muziek uit andere apps en zwijgt als de iPhone op stil staat, tenzij Instellingen › Spelen › "Geluid ook in stille modus" aan staat (`AppSettings.soundWhenSilent`, audiosessie `.playback` in plaats van `.ambient`);
  - save states met screenshot, een auto-save bij stoppen, en opslag van in-game saves (batterijgeheugen en klok); houd een save state op de spelpagina ingedrukt om hem te verwijderen;
  - snel vooruit (2×) en screenshots naar Foto's;
  - controllers (GameController, zie **Controllers** hieronder) en een hardware-toetsenbord.
- **Nintendo 64**:
  - GLideN64 tekent met OpenGL ES 3, op 640×480, steeds in hetzelfde framebuffer, zoals in RetroArch. Na elk beeld kopieert de GPU het naar een van drie IOSurfaces, die het Metal-scherm direct toont. (Eerst kreeg de kern elk beeld een ander framebuffer; dat gaf flikkeren, want GLideN64 tekent niet elk beeld opnieuw.) De simulator kan niet met OpenGL ES in een IOSurface tekenen; daar wordt elk beeld teruggelezen. Super Mario 64 draait zo zonder flikkeren op een iPhone 14 Pro.
  - De processor draait met de "cached interpreter", want iOS staat geen JIT toe.
  - Op het scherm zitten een analoge stick, A, B, de vier C-knoppen, L, R, Z en Start. Op een controller is de linkerstick de N64-stick en de rechterstick zijn de C-knoppen.
  - Per spel kies je op de spelpagina (Besturing) wat er in de controller zit: een Controller Pak (standaard, voor spellen die daarop opslaan) of een Rumble Pak, die trilt (`Game.rumblePak` → kernoptie `mupen64plus-pak1` t/m `pak4` = `rumble`). Het geldt vanaf de volgende start.
- **GameCube en Wii** (Dolphin):
  - De processor draait met de "cached interpreter", want iOS staat geen JIT toe. Sinds 23 oktober 2026 is dat die van iCube (Provenance, github.com/Provenance-Emu/dolphin-ios-jitless): een veel snellere versie voor apparaten zonder JIT, met blokken die direct naar elkaar springen, samengevoegde micro-operaties en snellere geheugentoegang. iCube meet daarmee Wind Waker op 1,3× echte snelheid op een iPhone 16 Pro Max. Hoe snel het op een iPhone 14 Pro is, meet je met Prestaties tonen.
  - Het beeld komt via Vulkan op MoltenVK, net als bij de 3DS. Eerst was dat OpenGL ES 3, maar daar mist iOS onder meer EXT_buffer_storage, waarmee Dolphin hoekpunten naar de GPU stuurt; Dolphin valt dan terug op een tragere manier (`glBufferSubData` of map-and-sync). Melee liep zo op een iPhone 14 Pro op 10% snelheid, terwijl beide threads maar 15% van een kern gebruikten: ze wachtten dus vooral, waarschijnlijk op de GPU. In de simulator tekent Dolphin nog met OpenGL ES.
  - Om sneller te lopen:
    - Dolphins processorthread krijgt de hoogste prioriteit (QoS "user interactive"), zodat iOS hem op de snelle kernen zet.
    - Dolphin is met ThinLTO gebouwd, zodat de interpreter ook over bestanden heen kan inlinen.
    - De app wacht niet meer elk beeld tot de GPU klaar is: het beeld komt één beeld later op het scherm (zie `GLRenderer.swift`). Dat geldt ook voor de N64.
    - Laden van de schijf gaat snel ("fast disc speed").
    - Het tempo volgt het geluid (`CoreProfile.pacesByAudio`), zodat het spel nooit sneller dan 100% loopt. Dolphins frame-stap loopt tot het volgende nieuwe beeld, en Dolphin stuurt per beeldveld van de console precies één veld geluid. Dat is nodig omdat Dolphin zijn beeldsnelheid meldt voordat het spel hem kiest: een PAL-spel als Mario Party 8 draait op 50 Hz terwijl Dolphin 59,94 fps meldt (de wissel geeft het alleen als SET_GEOMETRY door), en liep zo op 120%. Het geluid komt van Dolphins eigen thread soms net na de ronde binnen; het telt dan bij de volgende mee (`LibretroCore.takeAudioFrames`, `EmulationRunner.gameTimeBySound`). Gemeten op de iPhone 14 Pro: 50 rondes per seconde, 97–102% snelheid.
    - In Instellingen › Prestaties (of per spel op de spelpagina) kun je de processor van de GameCube en Wii langzamer zetten: 100%, 80% of 60%. Dan hoeft de interpreter minder te rekenen; sommige spellen worden daar juist trager van.
  - Shaders: elke nieuwe combinatie van effecten die een spel tekent, heeft een eigen shader nodig, en die compileren kost op een iPhone zo lang dat het spel hapert (Dolphins standaard is "Synchronous": het spel wacht). Sinds 23 oktober 2026 staat Attic, net als iCube, op hybride ubershaders (`dolphin_shader_compilation_mode` = 2): iets nieuws wordt eerst getekend met een algemene "ubershader" terwijl de eigen shader op de achtergrond klaar wordt. Daarbij staat "wacht op shaders" aan: voor het spel start compileert Dolphin de ubershaders en alle shaders die het spel eerder gebruikte (die bewaart Dolphin in de savemap van het spel, `User/Cache/Shaders`). De eerste start duurt daardoor langer. In Instellingen › Prestaties kies je ook Overslaan (iets nieuws even niet tekenen, het lichtst) of Wachten (de oude stand).
  - GameCube: de stick is de hoofdstick, L en R zijn de triggers, Z en Start zitten in het midden. De C-stick werkt met een controller (rechterstick).
  - Wii: per spel kies je op de spelpagina (Besturing) de controller die het spel verwacht. Het geldt vanaf de volgende start.
    - **Wii Remote + Nunchuk** (standaard): de stick is die van de Nunchuk, met de D-pad van de Wii Remote erboven; C en Z zijn de schouderknoppen, −, Home en + zitten in het midden.
    - **Wii Remote dwars**, zoals in New Super Mario Bros. Wii: D-pad, 1 en 2, met A en B als schouderknoppen.
    - **Classic Controller** (de Pro, met ZL, L, R en ZR als gewone knoppen): bijvoorbeeld Mario Kart Wii.
    - **GameCube-controller**: bijvoorbeeld Super Smash Bros. Brawl; de Wii Remote is dan losgekoppeld.
    - Met een Wii Remote volgt de aanwijzer je vinger op het beeld ("Tikken op beeld") of het richten van je iPhone ("Telefoon richten"): draai je hem naar links of rechts, of til je de bovenkant (of rechtop de achterkant) op of neer, dan beweegt de aanwijzer zoveel mee (ongeveer 20° van het midden tot de zijkant en 15° tot boven of onder). Attic telt daarvoor de draaiingen van de gyroscoop op (`TiltPointer.swift`), zodat het werkt hoe je de iPhone ook houdt; aan de rand blijft de aanwijzer staan. Bij de Classic en GameCube-controller is de rechterstick die van de controller zelf, dus is er geen aanwijzer.
    - **Midden-knop** (⌖ bovenin, naast snel vooruit; ook op het controllerscherm van een meespelende iPhone): richt je iPhone op het midden van het beeld en tik. De aanwijzer staat dan weer in het midden (`TiltPointer.recenter`) en hoe je de iPhone nu houdt, telt als de Wii Remote recht (`WiiMotion.level`). Nodig omdat het optellen van de gyroscoop langzaam wegloopt, en omdat het midden verschuift als je voorbij de rand draait. De knop staat er met een Wii Remote die beweging of "Telefoon richten" gebruikt.
    - **Beweging van de iPhone** (per spel, standaard aan, alleen met een Wii Remote): de versnellingsmeter van de iPhone is die van de Wii Remote, dus kantelen, zwaaien en schudden werken zoals op een Wii. De Wii Remote wijst waar de achterkant van de iPhone heen wijst; hoe ver je de iPhone achterover houdt als het spel start of verder gaat, telt als recht. Attic geeft de waarden via libretro's sensor-interface (`WiiMotion.swift`, `LibretroCore`) in g langs de assen van de Wii Remote; dwars draait Dolphin ze zelf een kwart. De gyroscoop gaat niet mee: daarmee zou Dolphin ook de aanwijzer laten draaien, en die volgt al je vinger of het kantelen. MotionPlus (Wii Sports Resort) zit er dus nog niet in.
    - Sommige spellen wisselen tussen een Wii Remote die naar het scherm wijst en een die je dwars houdt als een stuur (de races in Mario Party 8: houd 2 in en kantel). Kies dan tijdens het spelen "Wii Remote: Dwars" (onder het beeld, of in het menu) en draai de iPhone als een stuur. Alleen de beweging draait mee; de knoppen blijven die van de Nunchuk-indeling.
    - De Wii Remote-beweging en de aanwijzer delen één bewegingsmeting (`DeviceMotion.swift`), zoals Apple aanraadt.
    - Schud je iPhone en de Wii Remote schudt ook (Dolphins "Shake Wiimote", naast de echte beweging).
  - Dolphin leest spelaanpassingen, de lettertypes van de GameCube en Wii-bestanden uit zijn Sys-map. Die zit in de app (`Dolphin.bundle`, 9 MB); de app legt er bij het starten een koppeling naar in `System/dolphin-emu`.
  - Losse GameCube- en Wii-programma's (.dol) worden als GameCube herkend; Dolphin ziet zelf of het een Wii-programma is.
- **Dreamcast** (Flycast):
  - De processors (SH4, de ARM7 voor het geluid en de geluids-DSP) draaien met interpreters, want iOS staat geen JIT toe. Flycast doet dat zelf al zo in de iOS-simulator (`TARGET_NO_REC`).
  - Flycasts eigen vervanging van de BIOS (HLE) staat aan, dus spellen starten zonder BIOS-bestanden. Sommige spellen hebben een echte BIOS nodig; die kun je nog niet toevoegen.
  - Om sneller te lopen: de emulatie draait in een eigen thread met de hoogste prioriteit, beelden worden overgeslagen als het spel onder 95% van zijn snelheid zakt, en de geluids-DSP staat uit (dan mis je in sommige spellen wat galm).
  - De snelheid van de SH4 kies je in Instellingen › Prestaties (of per spel op de spelpagina): 25%, 50% of 100% van zijn echte 200 MHz. Flycasts interpreter telt elke instructie normaal als acht keer zijn cycli, een SH4 van 25 MHz; Sega Bass Fishing haalde daarmee maar 21 tot 39 van zijn 60 beelden per seconde, en liep dus trager dan 1×. Op 25% (50 MHz, de standaard) haalt het de 60. Elke stap omhoog kost ongeveer twee keer zoveel rekenwerk: op 100% kost alleen al de processor van Bass Fishing op een Mac met M2 (vergelijkbaar met de iPhone 14 Pro) 0,8 tot 2 processorkernen.
  - Flycast emuleert in zijn eigen thread en geeft per `retro_run` één beeld van het spel terug. Bij een spel dat 30 beelden per seconde tekent, duurt zo'n beeld twee schermverversingen; de app wacht daarom zo lang als het geluid van dat beeld duurt in plaats van één beeldtijd (`CoreProfile.pacesByAudio`), anders liep zo'n spel twee keer te snel.
  - Spellen als cue/bin (zoals Redump ze maakt), GDI, CDI of CHD, los of in een zip of 7z. Een cue-sheet is van de Dreamcast als hij een "HIGH-DENSITY AREA" (het GD-ROM-deel) noemt, of als een spoor begint met de opstartkop van de Dreamcast ("SEGA SEGAKATANA"); anders blijft het een PlayStation-schijf. Losse Dreamcast-programma's (.elf) worden herkend aan hun processortype.
  - Dreamcast-spellen die een eerdere versie als PlayStation-schijf importeerde, zet de app bij het starten vanzelf om naar Dreamcast, met de goede hoes.
  - Elk spel heeft zijn eigen geheugenkaart (VMU) in zijn eigen savemap, `<spelcode>.A1.bin`, dus het ene spel kan de kaart niet volschrijven voor het andere. Flycast stopt een geheugenkaart pas in de controller als de app hem over alle vier controllerpoorten heeft verteld; de app meldt daarom poort 2 tot en met 4 als leeg.
  - Op het scherm: de D-pad met daaronder de stick, A, B, X, Y, de L- en R-trigger en Start.
  - In de simulator getest met het testprogramma (beeld, stoppen met auto-save en verder spelen vanaf de auto-save) en met Sega Bass Fishing als cue/bin in een 7z: herkend, hoes gevonden, de geheugenkaart werkt, en het spel is speelbaar. De simulator tekent OpenGL in software (honderden milliseconden per beeld), dus hoe snel spellen lopen, moet de iPhone uitwijzen.
  - Flycast vangt zolang een Dreamcast-spel loopt geheugenfouten op (SIGSEGV en SIGBUS), om te zien wanneer een spel in beveiligde texturen schrijft. Fouten buiten zijn eigen geheugen geeft hij door aan de vorige afhandeling, en bij stoppen zet hij die terug. Zie je `fault_handler` in een crashrapport, dan zat de echte fout dus ergens anders.
- **PSP** (PPSSPP):
  - De processor draait met PPSSPP's IR-interpreter, de snelste zonder JIT (die doet PPSSPP op iOS zelf ook al).
  - Het beeld komt van OpenGL ES 3, net als bij Dolphin en Flycast, op twee keer de resolutie van de PSP (960×544): scherper op een iPhone en weinig werk voor de GPU.
  - PPSSPP leest zijn spelaanpassingen (`compat.ini`), de lettertypes van de PSP, de VFPU-tabellen en de plaatjes en vertalingen van de PSP-schermpjes (opslaan, laden) uit `PPSSPP.bundle` (16 MB); de app legt er een koppeling naar in `System/PPSSPP`. De lettertypes zijn PPSSPP's eigen vervanging, dus je hebt geen systeembestanden nodig.
  - De geheugenkaart (Memory Stick, met de opgeslagen spellen) staat per spel in `Saves/<spel>/PSP`.
  - Spellen als ISO of CSO, en EBOOT.PBP (ook homebrew).
  - Op het scherm de D-pad met daaronder de stick, zoals op een PSP; △, ○, ✕ en □, L en R, Select en Start.
  - Een save state is 40 MB, dus terugspoelen staat uit.
  - In de simulator getest met het PSP-testprogramma: beeld (3D), knoppen en stick, stoppen met auto-save en verder spelen. Video's in spellen werken daar niet: PPSSPP's FFmpeg heeft geen simulatorversie. Op de iPhone nog niet getest.
- **Nintendo 3DS** (Azahar):
  - De processor draait met Azahars interpreter, want iOS staat geen JIT toe. Hoe snel spellen daarmee lopen, moet de iPhone uitwijzen.
  - Azahar tekent met Vulkan; op Apple-apparaten is er geen OpenGL voor. Attic geeft het Vulkan via MoltenVK (Vulkan op Metal): `AtticVulkan.c` maakt het Vulkan-apparaat (of laat Azahar het maken), geeft de kern een Metal-surface op een laag die nooit in beeld komt (Dolphin bouwt zijn door libretro nagebootste swapchain alleen als de frontend een surface meegeeft, zoals RetroArch doet; zonder bleef het beeld zwart), maakt de instance minstens Vulkan 1.1 (Dolphin vraagt 1.0, en dan verbergt MoltenVK functies die Dolphins geheugenbeheer nodig heeft), beantwoordt libretro's Vulkan-aanroepen, en kopieert elk klaar beeld naar het geheugen, één beeld achter, zodat de processor zelden op de GPU wacht.
  - In de simulator kan Metal geen "lineaire textures" maken op gedeeld geheugen, en die gebruikt Azahars Vulkan-renderer. Daar tekent Azahar in software: traag, maar je ziet het spel.
  - De gewone 3DS wordt nagebootst, niet de New 3DS: zijn langzamere processor geeft de interpreter minder werk per beeld. Spellen die alleen op de New 3DS draaien, starten niet.
  - Spellen moeten ontsleuteld zijn: .3ds/.cci, .cxi en .cia, en homebrew als .3dsx. Een versleuteld spel weigert de import meteen, met uitleg (Azahar kijkt naar dezelfde NoCrypto-vlag). De lettertypes van de 3DS zitten als vrije vervanging in Azahar, dus je hebt geen systeembestanden nodig.
  - Een CIA is een installatiebestand; Azahars libretro-kern start dat niet. Bij het importeren haalt de app het spel zelf (inhoud 0, een NCCH) eruit en bewaart dat als .cxi; de handleiding en de rest van de CIA vallen weg. Updates en DLC als CIA kan de app nog niet installeren. Een CIA die een eerdere versie heel bewaarde, zet de app bij het starten vanzelf om.
  - Beide schermen, staand onder elkaar en liggend naast elkaar; het onderste scherm (320 van de 400 pixels breed, in het midden) is een aanraakscherm. De stick is de Circle Pad.
  - Azahars eigen gegevens (de SD-kaart en NAND van de 3DS, met de opgeslagen spellen, en de shader-cache) staan per spel in `Saves/<spel>/Azahar`.
  - Terugspoelen staat uit: Azahar pakt voor elke save state het hele geheugen van de 3DS in.
  - `patches/azahar/savestate-revision.diff`: het bouwscript kopieert de bron zonder .git, dus Azahars revisie is "UNKNOWN". Een save state kreeg daardoor 20 nullen als revisie, en het laden vergeleek die als hex met "UNKNOWN", zodat geen enkele state laadde. Nu vergelijkt het laden dezelfde bytes die het opslaan schrijft; de oude states (nullen) laden ook. Let op bij een nieuwere Azahar: de revisie blijft "UNKNOWN", dus states van de oude versie worden dan niet geweigerd. Geef de nieuwe versie dan een echte revisie, of wis de 3DS-states.
  - In de simulator getest met de homebrew ftpd (github.com/mtheall/ftpd, GPL 3): starten, beide schermen, aanraken, stoppen met auto-save en verder spelen. En met Super Mario 3D Land als CIA: importeren (de .cxi eruit gehaald, met spelcode AREP en hoesje), starten tot het welkomstscherm, en een auto-save van 16 MB. Vulkan is op de iPhone nog niet getest.
- **Nintendo DS**: beide schermen, staand onder elkaar en liggend naast elkaar. Het onderste scherm is een aanraakscherm: tikken en slepen met je vinger. Spellen starten direct, met de vervangende BIOS die in melonDS zit (FreeBIOS); je hebt geen BIOS-bestanden nodig. De DSi-stand wordt niet gebruikt.
- **PlayStation**: cue/bin, CHD, PBP, ISO en losse programma's (PS-EXE). PCSX gebruikt zijn ingebouwde HLE-BIOS; sommige spellen hebben een echte BIOS nodig (zie "Nog niet gebouwd"). Op het scherm zitten L1, L2, R1 en R2. De controller is een digitale PlayStation-controller, zonder analoge sticks.
- **Aanraakknoppen**: indelingen per systeem uit het prototype, staand en liggend. Je kunt met je duim van knop naar knop schuiven, en de D-pad heeft acht richtingen. De stick (N64, GameCube, Wii, Dreamcast, 3DS en PSP) is analoog en drukt geen D-pad in. Bij de PSP en Dreamcast staat de D-pad er ook, boven de stick. Een schuifregelaar (0–100%) zit in Menu › Besturing en in Instellingen › Spelen. Bij 0% zijn de knoppen onzichtbaar maar werken ze nog.
- **Controllers** (`Emulation/GameControllerInput.swift`, Instellingen › Controllers in `Views/ControllersView.swift`):
  - De eerste Bluetooth-controller speelt speler 1, samen met de knoppen op het scherm. In een spel voor meer spelers wordt elke volgende controller speler 2, 3 of 4 (een melding "… is speler 2"); is er geen plaats meer, of is het spel voor één speler, dan speelt hij ook speler 1. Controllers en meedoende iPhones delen dezelfde plaatsen: `EmulatorSession.claimPort`/`releasePort` (protocol `PlayerSeats`). Controllers die al verbonden zijn als het spel start, worden ingeplugd zodra de kern geladen is. Het lampje van de controller toont het spelernummer (`playerIndex`).
  - Knoppen indelen: in Instellingen › Controllers kies je per systeem (bij de Wii per soort controller, `ControlScheme`) welke consoleknop elke controllerknop indrukt, of "Niets". De knoppen heten naar hun plek (onderste, rechter, linker, bovenste knop), zodat het voor Xbox, PlayStation en Switch hetzelfde is; standaard zit A rechts en B onder, zoals bij Nintendo. Alleen wijzigingen worden bewaard (`AppSettings.controllerMappings`, `Model/ControllerMapping.swift`); "Standaard herstellen" wist ze. Het geldt vanaf het volgende spel, ook op een iPhone die als controller meedoet. Bij een Wii Remote staat R2 standaard op Schudden.
- **Trillen** (`Emulation/Rumble.swift`): kernen vragen de libretro-trilkoppeling (`RETRO_ENVIRONMENT_GET_RUMBLE_INTERFACE`); `RumbleLevels` houdt per poort de sterkte bij en geeft alleen veranderingen door, `RumbleOutput` stuurt ze naar de controllers van die speler die kunnen trillen (Core Haptics via `GCController.haptics`), anders voor speler 1 naar de iPhone zelf, en voor een meedoende iPhone als bericht naar die iPhone. Bij pauze stopt alles. Aan/uit: Instellingen › Spelen › Trillen in spellen.
  - Welke spellen trillen: GameCube en Wii (Dolphin, `dolphin_enable_rumble` staat standaard aan), Dreamcast (Flycast heeft standaard een Purupuru-pack in slot 2), N64 met Rumble Pak (per spel kiezen), Game Boy- en GBA-spellen met een trilmodule (mGBA). PlayStation nog niet: PCSX trilt alleen met een DualShock als controllertype.
  - De simulator heeft geen trilmotor; daar is het alleen in het log te volgen (`app.attic:emulation`, "Trillen speler N").
- **Prestaties per spel**: Instellingen › Prestaties bevat de standaard voor alle spellen (GameCube en Wii: processor en shaders; Dreamcast: processor). Op de pagina van een spel staat onder Prestaties per instelling een keuzemenu: "Standaard" volgt Instellingen, een andere keuze geldt alleen voor dat spel (bewaard in `library.json`, `performance`). De keuze geldt vanaf de volgende keer dat je het spel start. Nieuwe instellingen voeg je toe in `Model/PerformanceSetting.swift`.
- **Samen spelen** (NES, SNES, PlayStation: 2 spelers; N64, GameCube, Wii, Dreamcast: 4): andere iPhones met Attic doen mee als controller.
  - Op de iPhone met het spel: open het menu en zet "Andere iPhones laten meedoen" aan (onthouden in `AppSettings.allowPlayers`). Wil een iPhone meedoen, dan verschijnt bovenin "Een iPhone wil meedoen · Als speler N" met Nee en Toestaan. In het menu staan de spelers; tik op een speler om hem te laten stoppen.
  - Op de andere iPhone: de controllerknop naast de + in de bibliotheek toont de spellen in de buurt (de knop voor raster/lijst staat naast het zoekveld). Na toestemming toont die iPhone alleen de knoppen van dat systeem (en een controller die erop is aangesloten speelt mee).
  - Verbinding: Bonjour (`_attic-pad._udp`) met kleine UDP-berichten, ook zonder gedeeld wifi-netwerk via peer-to-peer wifi zoals AirDrop (`Multiplayer/PadLink.swift`). Instellingen › Prestaties › "Samen spelen ook zonder wifi" uit (`AppSettings.directWiFi`) houdt het verkeer op het wifi-netwerk; uit op één van beide iPhones is genoeg, en het geldt vanaf het volgende spel. De controller stuurt zijn knoppen bij elke wijziging en anders elke 50 ms; de host herhaalt zijn antwoord elke halve seconde. Vijf stille seconden betekenen dat de verbinding weg is: de host plugt die speler uit, de controller meldt "Verbinding verbroken".
  - De host zet de invoer rechtstreeks van zijn netwerkthread door naar `RemotePlayers`, die de emulatiethread per beeld uitleest voor poort 1–3; `LibretroCore.setPlayer` plugt een controller in of uit terwijl het spel loopt. Bij de N64 worden de C-knoppen per speler de rechterstick.
  - iOS vraagt de eerste keer toestemming voor het lokale netwerk (`NSLocalNetworkUsageDescription`, `NSBonjourServices` in Info.plist).
  - Testen op één Mac: twee simulators vinden elkaar via Bonjour en verbinden over `lo0` (sinds de firewall het toelaat; eerder werkte alleen 127.0.0.1). `TestPrograms/multiplayer/fakepad.py <poort>` is een nepcontroller (vraagt via 127.0.0.1 om mee te doen bij een host-simulator en drukt na toelating A, B en de stick); `fakehost.py <poort>` is een nephost die elke controller toelaat als speler 2 en de knoppen afdrukt (aanmelden met `dns-sd -R Nep-host _attic-pad._udp local <poort> v=3 game=Nep-host system=gc`; de nephost laat de controller ook elke vier seconden een seconde trillen). De poort van de host staat in zijn log (`nw_listener … endpoint: ::.<poort>`).
  - Trillen: de host stuurt een meedoende iPhone een trilbericht als zijn sterkte verandert en elke halve seconde opnieuw, zodat een verloren bericht vanzelf wordt rechtgezet. Die iPhone trilt zelf, of de controller die erop zit. Berichten zijn sindsdien versie 3.
  - Wii: elke meedoende iPhone is een eigen Wii Remote van hetzelfde soort als bij de host (Nunchuk, dwars, Classic of GameCube; de host stuurt het mee). Zijn versnellingsmeter gaat mee in de invoer (60 keer per seconde, in duizendsten g) en Dolphin krijgt hem per speler via de sensor-interface (`LibretroCore.remoteMotion`; Dolphin vraagt bij het starten per poort of er een versnellingsmeter is, dus die worden voor poort 1–3 al aangeboden voordat iemand meedoet; zonder beweging geldt "recht"). De aanwijzer: "Telefoon richten" (gyro, `TiltPointer`) of een aanraakvlak dat voor het tv-beeld staat; bij de Nunchuk ook Rechtop/Dwars; schudden is de schud-knop. Berichten zijn sindsdien versie 2.
  - Meten (voor een vloeiendere Wii Remote van meespelers): elk invoerbericht krijgt achteraan een volgnummer en de verzendtijd van de controller (`InputStamp`, 0,1 ms). Omdat het achteraan staat, lezen oudere 0.5-builds het bericht gewoon; de versie blijft 3. Met Prestaties tonen aan staat op de iPhone met het spel per speler: de route (`rechtstreeks (awdl0)`, `wifi-netwerk (en0)`), berichten per seconde, het gat tussen twee berichten (mediaan, p95, grootste), "netwerk" (hoeveel langer dan het snelste bericht een bericht onderweg was, los van hoe gelijkmatig de controller verstuurde), hoeveel er kwijt is, en hoeveel beelden geen nieuw bericht kregen of twee of meer (`LinkMonitor`, `RemotePlayers.frameCounts`). Op de controller-iPhone: de route, berichten per seconde en hoe laat de bewegingssensor zijn metingen aflevert (`DeviceMotion.delivery`). De host schrijft het ook naar `Library/Caches/Samenspelen.log` (elke seconde) en `Samenspelen-aankomst.csv` (elk bericht), op te halen zoals Prestaties.log. `TestPrograms/multiplayer/fakepad_timing.py <poort>` is een nepcontroller met een hobbelige verbinding (60 ms ophouden per seconde, 2% kwijt) om de cijfers te controleren.
  - Getest met New Super Mario Bros. Wii in twee simulators: meedoen, de dwarse knoppen (1 = bit 0, 2 = bit 8, D-pad) komen aan, en Dolphin blijft draaien als Wii Remote 2 wordt ingeplugd. Beweging en echte vertraging zijn alleen op echte iPhones te testen. Op twee echte iPhones (29 okt) liep het via hetzelfde wifi-netwerk vloeiend en haperde het rechtstreeks (AWDL) flink.
  - Tikvlakken van de knoppen en de tikken zelf zijn in venstercoördinaten (`controlTarget`, `TouchLayerView`): de UIKit-aanraaklaag begon op het controllerscherm onder de statusbalk en de SwiftUI-knoppen 47 punten lager, waardoor 1 en 2 verschoven reageerden.
- **Scherm blijft aan** zolang een spel loopt (ook met alleen een controller of beweging); met het menu open mag het weer uit.
- **Prestaties tonen** (Instellingen › Prestaties): boven het spel staan dan het aantal beelden per seconde, de snelheid van het spel (hoeveel speltijd het geluid per seconde bevat, 100% is volle snelheid) en de twee threads die de meeste processortijd gebruiken, in procenten van één kern. "emulatie" is de thread van de app die de kern draait (en bij Flycast tekent), "Flycast" is Flycasts eigen emulatiethread en "app" de hoofdthread. Staat er een thread op bijna 100%, dan houdt die het spel op.
  - De cijfers gaan ook naar `Library/Caches/Prestaties.log` in de app (met rondes per seconde en de beeldsnelheid die de kern meldt). Ophalen van de iPhone: `xcrun devicectl device copy from --device <udid> --domain-type appDataContainer --domain-identifier app.attic --source Library/Caches/Prestaties.log --destination <map>`.
- **Terugspoelen**: houd ⏪ naast snel vooruit ingedrukt, dan loopt het spel terug, drie keer zo snel als het speelde, tot een minuut ver. Laat je los, dan speel je verder vanaf dat moment.
  - De app maakt daarvoor steeds een save state: tien per seconde bij kleine systemen, vier bij de PlayStation, twee bij de DS en N64. Ze worden met LZ4 ingepakt, samen hooguit 96 MB.
  - Bij de GameCube, Wii en Dreamcast staat terugspoelen uit: een save state is daar tientallen megabytes. Flycast zet bovendien voor elke save state zijn emulatie even stil.
  - Uitzetten kan in Instellingen › Spelen.
- **AirPlay naar je tv**: zet op je iPhone Scherm synchroniseren naar je Apple TV aan. De tv toont dan het spel op volle grootte en je iPhone wordt de controller, met alleen de knoppen. Bij de DS en 3DS komt alleen het bovenscherm op de tv, zo groot als past; het aanraakscherm staat groot op je iPhone (staand zo breed als past, liggend zo hoog als past met de knoppen ernaast) en bovenin staat "Op je tv". Wie alles op de tv wil zien, kiest in het menu "Op de tv: Beide schermen" (`AppSettings.tvBothScreens`); het aanraakscherm blijft dan ook op de iPhone. Zonder spel toont de tv "Kies een spel op je iPhone". AirPlay-synchronisatie heeft wat vertraging (ongeveer een tiende seconde).
  - Vanaf iOS 27 krijgt een app pas een eigen tv-scene als een view controller op het scherm een "scene accessory" heeft geregistreerd (`UIViewController.registerSceneAccessory`, `UISceneAccessory.externalNonInteractive`); anders spiegelt iOS de iPhone. Attic registreert er een op de bibliotheek (tv: "Kies een spel") en een op de speler (tv: het spel); iOS toont die van het bovenste scherm. Zie `externalDisplayAccessory()` in `ExternalDisplay.swift`. Voor iOS 18–26 komt de scene vanzelf, via het scene-manifest in Info.plist en `AppDelegate`.
- **Chromecast**: in het menu van een spel staat "Chromecast" met de Chromecasts op je wifi. Tik er een aan; de tv toont dan het spel en je iPhone wordt de controller, net als bij AirPlay (ook de DS-keuze "Op de tv" werkt zo). "Loskoppelen" zet de tv terug. Het geluid blijft voorlopig op de iPhone.
  - Attic gebruikt geen Cast-bibliotheek van Google: die is gesloten en past niet bij de GPL. Attic spreekt het protocol zelf (`Attic/Cast/`): een TLS-verbinding op poort 8009 met kleine JSON-berichten (`CastChannel`), die de ingebouwde spiegel-ontvanger van de Chromecast start, dezelfde die Chrome gebruikt als je een tabblad cast (app-ID `0F5096E8`). Daarna gaat het beeld als H.264 met Cast Streaming over UDP (`CastStreamer`): RTP-pakketjes met een Cast-kop, per beeld versleuteld met AES-128-CTR, en RTCP-berichten terug met wat er binnen is en wat opnieuw moet. Er is dus geen registratie bij Google nodig.
  - `CastCapture` tekent het spel 60 keer per seconde scherp in 1280×720 (dezelfde shader als op de iPhone), `CastVideoEncoder` maakt er met de hardware H.264 van (lage vertraging, geen beeldvolgorde-trucs, een beginbeeld alleen als de tv erom vraagt of elke 10 s). De tv speelt elk beeld 100 ms nadat het gemaakt is (`Chromecast.targetDelay`); daarbinnen kan een verloren pakketje opnieuw. Met Prestaties tonen aan staat in het menu hoeveel beelden aankwamen en hoeveel pakketjes opnieuw moesten.
  - Getest met een echte Chromecast via wifi (29 okt). Zonder Chromecast kun je testen met een nep-Chromecast op de Mac, zie Openen en draaien.
- **Systemen**: alle 14 systemen. Mega Drive en arcade worden al herkend en krijgen een spelpagina, hun knoppenindeling en een hoesje, met een melding in welke fase de emulator komt.
- **Demo-cartridge en testprogramma's**: een eigen klein GBA-programma (`DemoCartridge/`) en acht testprogramma's voor NES, SNES, N64, DS, PS1, GameCube, Dreamcast en PSP (`TestPrograms/`). Daarmee test je beeld, knoppen, aanraken en opslaan zonder eigen back-ups. Het zijn geen bestaande spellen.

## Openen en draaien

1. Open `Attic.xcodeproj` in Xcode (26 of nieuwer). Xcode laadt het lokale pakket `AtticCores` vanzelf, met de kant-en-klare kernen in `AtticCores/Frameworks`.
2. **Simulator**: kies een iPhone-simulator en druk op Run.
3. **Je iPhone**:
   - Log in Xcode in met je Apple ID: Xcode › Settings › Accounts › +.
   - Zet op de iPhone Instellingen › Privacy en beveiliging › Ontwikkelaarsmodus aan (de iPhone herstart dan).
   - Kies je iPhone als doel.
   - Kies bij target Attic › Signing & Capabilities je eigen Team. Een gratis Apple ID is genoeg.
   - Zegt Xcode dat de bundle-ID al bezet is, verander `app.attic` dan in iets anders.
   - Start de app de eerste keer niet, vertrouw dan de ontwikkelaar: Instellingen › Algemeen › VPN en apparaatbeheer › Apple Development: … › Vertrouw. Na een nieuwe installatie kan iOS daar opnieuw om vragen ("Verifieer app", dat heeft internet nodig).
   - Met een gratis account moet je de app elke 7 dagen opnieuw installeren.

In de simulator kun je het Mac-toetsenbord gebruiken: pijltjes of WASD voor de D-pad, X = A, Z = B, Q = L, E = R, Enter = Start, Backspace = Select, en Esc voor het menu.

Start je een debug-build met de optie `-AtticLandscape` (Product › Scheme › Edit Scheme › Arguments), dan draait de interface vanzelf naar liggend. Handig om de liggende speler te testen zonder de simulator te draaien.

Met `-AtticFakeTV` doet een debug-build alsof er een tv aan hangt: het tv-beeld staat in een klein venster over de iPhone, en de speler gedraagt zich als bij AirPlay. De simulator van Xcode 27 kan vanaf de opdrachtregel geen extern scherm aansluiten.

Chromecast testen zonder Chromecast kan met de programma's in `TestPrograms/chromecast/`:
- `fake_receiver.py` speelt de spiegel-ontvanger na. Hij gooit expres 3% van de pakketjes weg, vraagt na 2 s een nieuw beginbeeld, en schrijft de beelden die hij ontvangt naar `frames.bin`.
- `castproef.swift` cast vanaf de Mac een bewegend testbeeld met dezelfde code als de app; met `ruis` kost elk beeld veel pakketjes. Met een echte Chromecast: `castproef <adres van de Chromecast>`.
- `decode_check.swift` zet `frames.bin` terug om naar plaatjes en telt de beelden die niet af te spelen zijn.
- Voor de app in de simulator: start de nep-ontvanger met `alle` en kondig hem aan als Chromecast met `dns-sd -R Nep-Chromecast _googlecast._tcp local <poort> fn=Nep-tv`. Dan staat "Nep-tv" in het menu.

De bouw- en startregels staan bovenin elk bestand.

## Uitbrengen via TestFlight

1. Hoog het versienummer op in het Xcode-project: `MARKETING_VERSION` (bijv. 0.5) en `CURRENT_PROJECT_VERSION` (elke upload een hoger buildnummer).
2. Archief: `xcodebuild archive -project Attic.xcodeproj -scheme Attic -configuration Release -destination generic/platform=iOS -archivePath "~/Library/Developer/Xcode/Archives/<datum>/Attic <versie> (<build>).xcarchive" -allowProvisioningUpdates DEVELOPMENT_TEAM=<jouw team-ID>`. Het staat dan ook in Xcode › Window › Organizer.
3. Uploaden: `xcodebuild -exportArchive -archivePath <archief> -exportPath <map> -exportOptionsPlist ExportOptions-upload.plist -allowProvisioningUpdates` (methode `app-store-connect`, `destination` `upload`; met `export` krijg je alleen een .ipa). Xcode tekent met een door Apple beheerd Apple Distribution-certificaat. Of in de Organizer: Distribute App › App Store Connect.
4. Daarvoor moet de app in App Store Connect bestaan (Apps › + › Nieuwe app, bundle-ID `app.attic`); anders zegt de upload "App record … not found".
5. Na de upload verwerkt Apple de build (een kwartier of zo); daarna staat hij onder TestFlight. Interne testers (gebruikers van het eigen team) kunnen meteen; externe testers pas na een korte beoordeling door Apple.

Wat de App Store vraagt en al geregeld is:
- `ITSAppUsesNonExemptEncryption` = NO in Info.plist: Attic gebruikt alleen de versleuteling die in iOS zelf zit (HTTPS voor de hoesjes; voor de Chromecast TLS via Network en AES via CommonCrypto), dus App Store Connect vraagt niet bij elke build naar encryptie.
- Privacymanifesten: `Attic/PrivacyInfo.xcprivacy` (UserDefaults, bestandsdatums, tijdmeting) en een eigen manifest in elk kernframework, dat `build_cores.py` maakt uit de symbolen die de kern gebruikt (`write_bundle_files`). Geen tracking, geen verzamelde gegevens.
- De kernframeworks hebben nog geen dSYM's: de upload waarschuwt daarvoor, maar lukt wel (alleen crashes in een kern zijn dan niet te herleiden).
- De kernframeworks hebben `CFBundleVersion` 1 (de App Store wil alleen cijfers); de commit van de kern staat in `AtticCoreCommit`.
- Het app-icoon komt uit `Artwork/attic-logo.png` (het logo van Attic; de naam en het logo vallen niet onder de GPL, zie README › Naam en logo); `Artwork/make_icon.swift` snijdt het bij tot het vierkant en vult de hoeken met de achtergrond, want iOS rondt de hoeken zelf af.

## Opbouw

| Map | Inhoud |
|---|---|
| `Attic/Design` | Kleuren, lettertypes (variabele fonts) en vaste onderdelen uit het prototype |
| `Attic/Model` | Systemen, spellen, bibliotheek, instellingen, save states, navigatie, en het bijwerken van titels en hoesjes (`GameMetadata.swift`) |
| `Attic/Import` | Zip- en 7z-uitpakker, herkenning, de spellendatabase (`GameDatabase.swift`), checksums en spelcodes (`GameFingerprint.swift`), het ophalen van hoesjes (`BoxArtFetcher.swift`), de vier importstappen en de map in de gaten houden |
| `Attic/Emulation` | libretro-frontend, emulatiethread, terugspoelen (`RewindBuffer.swift`), Metal-beeld, OpenGL ES voor N64, GameCube, Wii en Dreamcast (`GLRenderer.swift`), geluid, invoer en controllers, en per kern de instellingen (`CoreProfile.swift`) |
| `Attic/Views` | De schermen: bibliotheek, spelpagina, importeren, speler, systemen, instellingen, en het tv-beeld via AirPlay (`ExternalDisplay.swift`) |
| `Attic/Cast` | Spelen op een Chromecast: vinden, het Cast-protocol, Cast Streaming en de H.264-encoder (`Chromecast.swift` knoopt ze aan elkaar) |
| `Attic/Resources` | De spellendatabase (`GameDB.sqlite`), lettertypes, de demo-cartridge en de licentieteksten |
| `AtticCores` | Swift-pakket: de libretro-API met Vulkan voor de 3DS (`AtticVulkan.c`, op MoltenVK), mGBA en de 7z-decoder van 7-Zip als broncode, en de andere kernen en MoltenVK als XCFrameworks in `Frameworks/` |
| `Cores` | Bouwscript voor de kernen (`build_cores.py`), de koppelcode `attic_core.c` en de aanpassingen aan de kernen in `patches/` |
| `Database` | Bouwscript voor de spellendatabase (`build_database.py`) |
| `DemoCartridge` | Broncode en bouwscript van de demo-cartridge |
| `TestPrograms` | Broncode en bouwscripts van de testprogramma's, en de gebouwde bestanden in `out/` |

mGBA wordt als broncode in de app gecompileerd, met een eigen voorvoegsel (`mgba_retro_run` enzovoort, zie `AtticCores/Package.swift`). De andere kernen zijn elk een eigen framework in de app, zoals `NestopiaCore.framework`. Zo'n framework exporteert maar één functie (`attic_nestopia_core()`), zodat de interne namen van de kernen niet kunnen botsen. De kernen worden altijd geoptimaliseerd gebouwd, ook in een debug-build van de app.

## Kernen opnieuw bouwen

```bash
python3 Cores/build_cores.py
```

Het script haalt elke kern op bij de vastgezette versie (zie de tabel onderaan), past de patches toe en bouwt hem voor iPhone en simulator. De frameworks komen in `AtticCores/Frameworks`, de bronnen en tussenbestanden in `Cores/.build` (ruim 550 MB). Alles samen duurt ongeveer een kwartier. Eén kern kan ook, bijvoorbeeld `python3 Cores/build_cores.py mupen64plus`. Je hebt Xcode, git en Python 3 nodig, en internet voor het ophalen.

Dolphin, Flycast, Azahar en PPSSPP worden met CMake gebouwd in plaats van met make; Dolphin duurt ongeveer tien minuten, Azahar en PPSSPP ongeveer twintig. Heb je CMake niet, haal het dan van cmake.org en geef het pad mee: `python3 Cores/build_cores.py dolphin --cmake /pad/naar/cmake`. Het script kopieert ook Dolphins Sys-map naar `Attic/Resources/Dolphin.bundle`.

Verander je de `make_args` van een kern, gooi dan eerst zijn map in `Cores/.build/work` weg. Make bouwt alleen opnieuw wat ouder is dan de broncode, niet wat met andere instellingen gebouwd is.

### Aanpassingen aan de kernen

iOS staat geen JIT toe: een app mag geen geheugen uitvoerbaar maken. Daarom:

- **bsnes**: de contextwissel van libco staat als gewone assembly in de app in plaats van als machinecode die met `mprotect` uitvoerbaar wordt gemaakt (`patches/bsnes/libco-aarch64.c`).
- **PCSX ReARMed**: gebouwd zonder dynarec, dus met de interpreter. Daarnaast twee patches. Paden mogen langer zijn dan 255 tekens (`patches/pcsx/config.h`), anders kon PCSX geen spellen en geheugenkaarten in de app-map openen. En de aanroep `ptrace(PT_TRACE_ME)` is eruit (`patches/pcsx/no-ptrace.diff`): die was voor de dynarec bedoeld, maar daarna kon iOS de app niet meer afsluiten.
- **melonDS**: gebouwd zonder JIT en zonder OpenGL; het tekent met de software-renderer, in een eigen thread.
- **Mupen64Plus-Next**:
  - Zonder paraLLEl-RSP en paraLLEl-RDP: die hebben een JIT en Vulkan nodig. Het beeld komt van GLideN64 (OpenGL ES 3), het geluid en de microcode van de HLE-RSP.
  - De processor draait met de cached interpreter (`CoreProfile.swift`).
  - Ook zonder de angrylion-renderer en de cxd4-RSP: die zijn op een telefoon te traag en Attic gebruikt ze niet.
  - Met de zlib van iOS in plaats van de meegeleverde.
  - De meegeleverde libpng dacht door `TARGET_OS_MAC` dat hij op een oude Mac draaide; `patches/mupen64plus/libpng-math.diff` haalt dat weg.

- **Dolphin**:
  - De processor draait met de cached interpreter, en fastmem staat uit (`CoreProfile.swift`). Fastmem hoort bij de JIT en reserveert 12 GB adresruimte.
  - Gebouwd met Vulkan en zonder mGBA (de koppeling tussen GameCube en GBA). iOS heeft geen libvulkan die Dolphin kan openen; `patches/dolphin/libretro-vulkan-apple.diff` haalt de Vulkan-functies daarom uit de `vkGetInstanceProcAddr` die de app (MoltenVK) via libretro meegeeft. Zonder mGBA bestaan Dolphins GBA-instellingen niet; `patches/dolphin/no-mgba.diff` zet het stukje startcode dat ze gebruikt tussen `#ifdef HAS_LIBMGBA`.
  - curl dacht dat `pipe2` bestond, maar dat zit pas in iOS 27 (`HAVE_PIPE2=OFF`).
  - Bij het koppelen moet Foundation erbij: Dolphin gebruikt `NSProcessInfo`.
  - `patches/dolphin/cpu-thread-qos.diff` geeft de processorthread van Dolphin QoS "user interactive".
  - `patches/dolphin/icube-cached-interpreter.diff` zet de Cached Interpreter van iCube (Provenance-Emu/dolphin-ios-jitless @ 8fc454c, GPL 2 of later) in deze libretro-versie. Beide gaan uit van dezelfde Dolphin (2609, upstream 0d93fc0), dus de patch is precies wat iCube aan de processorkant veranderde: de mappen `PowerPC/CachedInterpreter` en `PowerPC/Interpreter`, `PowerPC.*`, `PPCAnalyst.*`, `MMU.*`, `JitInterface.cpp` en `Common/Visibility.h`, plus iCube's instellingen (`MAIN_CIR_*`, met iCube's standaardwaarden) in `MainSettings`. iCube's JIT-hulp voor iOS 26 (StikDebug, TXM) en de NEON-texturedecoder zitten er niet in.
  - Gebouwd met ThinLTO (`-flto=thin` bij het compileren en bij de laatste koppeling).
  - `libretro-vulkan-apple.diff` laat Dolphin ook een 8-bit swapchain kiezen: MoltenVK biedt eerst een 10-bit formaat aan, dat de app niet kopieert (zwart beeld).
  - `patches/dolphin/libretro-state-pause.diff`: een save state laden of maken pauzeert de processorthread echt (`CPUManager::PauseAndLock`). Zonder dat liep iCube's interpreter nog blokken uit een cache die het laden leegmaakte, en crashte de GameCube bij het laden van de auto-save.
  - `patches/dolphin/libretro-nunchuk-motion.diff`: libretro Dolphin koppelt de versnellingsmeter van de frontend alleen aan een losse Wii Remote; deze patch doet dat ook met een Nunchuk eraan.
  - `patches/dolphin/libretro-state-size.diff`: tussen het meten van een save state (`retro_serialize_size`) en het maken ervan draait de processorthread door, en bij de Wii kan de Bluetooth-wachtrij intussen groeien (zo'n 1 KB per bericht). Paste de state niet meer, dan kapte Dolphin hem zonder melding af: de Wii Remotes en zo nodig de processorregisters, die achteraan staan, ontbraken. Nu meldt de kern 1 MB extra ruimte, mislukt het maken als de state toch niet past, en wordt een state die maar half laadt teruggedraaid: zoals Dolphin zelf doet, bewaart `retro_unserialize` eerst de toestand van dat moment en zet die terug. (Een vangnet; de Wii-crash van 29 oktober had een andere oorzaak, zie hieronder.)
  - `patches/dolphin/libretro-wiimote-source.diff`: een save state onthoudt welke Wii Remotes verbonden waren. Laad je een state met speler 2 (een andere iPhone of controller) terwijl die er niet meer is, dan dacht het spel dat Wii Remote 2 er nog was en stuurde het hem een rapport (lampjes, trillen); in libretro heeft zo'n remote geen bron (`m_hid_source` is null bij een lege poort), en Dolphin crashte in `WiimoteDevice::ExecuteL2capCmd`. Nu wordt zo'n remote na het laden losgekoppeld, alsof zijn batterijen leeg zijn; hij komt terug als er weer een speler meedoet.

- **Flycast**:
  - Gebouwd met `TARGET_NO_REC`: de interpreters voor de SH4, de ARM7 en de geluids-DSP, zonder JIT.
  - `patches/flycast/emu-thread-qos.diff` geeft de emulatiethread QoS "user interactive" en de naam Flycast-emu (Flycast geeft threads alleen op Linux een naam).
  - `patches/flycast/interpreter-clock.diff`: de interpreter telde elke instructie als acht keer zijn cycli (`CPU_RATIO`, een SH4 van 25 MHz). Nu volgt die factor de optie `reicast_sh4clock` (in MHz, voorheen alleen voor de JIT): 200 is factor 1, 100 is 2, 50 is 4, tot Flycasts eigen 8. En Flycast slaat beelden over vanaf 95% snelheid in plaats van 85%: bij 85% bleef een spel op 85-90% hangen als de GPU net te traag was.
  - Gebouwd met ThinLTO.
- **PPSSPP**:
  - Gebouwd met de instellingen van PPSSPP's eigen iOS-toolchain (`USING_GLES2`, `MOBILE_DEVICE`), zonder Discord en UPnP.
  - FFmpeg (alleen voor video's in spellen) komt als kant-en-klare bibliotheek mee met PPSSPP. Voor de simulator is er geen versie, dus daar wordt PPSSPP zonder FFmpeg gebouwd (`simulator_cmake_args`). PPSSPP noemt de FFmpeg-map ten opzichte van de bron, en die kopie laat het bouwscript zonder .a-bestanden; daarom wijst `{source}` naar de checkout.
  - De koppen van OpenXR en miniupnp moeten erbij, ook al gebruikt de iOS-kern ze niet.
  - Gebouwd met ThinLTO.
- **Azahar**:
  - De processor en de vertex-shaders van de 3DS draaien met interpreters (`citra_use_cpu_jit` en `citra_use_shader_jit` uit in `CoreProfile.swift`). Dynarmic, de JIT, wordt wel meegebouwd maar niet gebruikt.
  - Gebouwd met Vulkan en zonder OpenGL; de software-renderer zit erin voor de simulator. Zonder de tests, SDL, OpenAL, cubeb, libusb en de webdiensten.
  - MoltenVK zit niet in de kern maar in de app (`AtticCores/Frameworks/MoltenVK.xcframework`, 1.4.1 van Khronos, alleen de iOS- en simulatordelen van de statische bibliotheek). De kern krijgt Vulkan via libretro's `get_instance_proc_addr`.
  - Gebouwd met ThinLTO.

Verder in `CoreProfile.swift`: Nestopia zonder NTSC-filter (scherpe pixels) en bsnes met ingebouwde versies van de coprocessors (DSP en dergelijke), zodat spellen zoals Super Mario Kart geen firmwarebestanden nodig hebben.

Mupen64Plus-Next wil het eerste beeld berekenen voordat het een save state aanneemt. Hervat je vanaf een save state, dan draait de app daarom eerst één beeld zonder geluid en laadt hij de state daarna nog eens (`EmulatorSession.swift`).

## Spellendatabase opnieuw bouwen

De database komt uit de libretro-database (github.com/libretro/libretro-database, CC BY-SA 4.0; gebruikt: commit 12c21cf van 10 oktober 2026). Alleen de mappen `metadat` en `dat` zijn nodig:

```bash
git clone --filter=blob:none --sparse https://github.com/libretro/libretro-database
git -C libretro-database sparse-checkout set metadat dat
python3 Database/build_database.py libretro-database
```

Het script schrijft `Attic/Resources/GameDB.sqlite` (10,6 MB): per spel het systeem, de checksum of spelcode, de No-Intro- of Redump-naam, de titel, het jaar en de regio. Bronnen per systeem staan bovenin het script (`SYSTEMS`):
- Cartridges (GB/GBC, GBA, NES/FDS, SNES, N64, DS, Mega Drive): de No-Intro-lijsten met checksums (bij de NES met én zonder iNES-kop) en spelcodes, jaartallen uit `metadat/releaseyear`.
- 3DS: No-Intro op spelcode (CTR-P-AREE wordt AREE), geen jaartallen.
- GameCube en Wii: Redump op de eerste vier tekens van de schijf-ID; titels en jaartallen uit de GameTDB-lijsten in `dat/`. Daarin staan ook mods met dezelfde code, dus het script neemt de vermelding waarvan de naam het meest op die van Redump lijkt.
- PlayStation: Redump op spelcode, jaartallen uit `metadat/developer`. PSP: No-Intro en Redump op spelcode. Dreamcast: Redump op spelcode, ook zoals de opstartkop hem afkapt (MK-51000-53 is daar MK-5100053) en Sega's eigen Amerikaanse schijven (51000 is MK-51000); geen jaartallen.
- Delen meer spellen een code, dan staat eerst het spel uit de regio van de code (de laatste letter bij Nintendo, de derde bij Sony) en een af spel vóór een demo. Een versie zonder jaar krijgt het jaar van een andere versie met dezelfde titel.

GameDB.sqlite is een bewerking van de libretro-database en valt daardoor ook onder CC BY-SA 4.0.

## Afwijkingen van het plan

- **Zip** gebruikt Apple's eigen Compression-framework in plaats van ZIPFoundation. Dat scheelt een afhankelijkheid en kan hetzelfde (stored en deflate, zip64). Deflate64, de methode die Windows soms bij bestanden boven 2 GB gebruikt, wordt niet ondersteund.
- **De spellendatabase zit in de app** in plaats van dat de app het online opzoekt. (Eerst was dat OpenVGDB; die heeft geen licentie, dus sinds 24 oktober 2026 de libretro-database.) Zo werkt herkennen ook zonder internet. Alleen de hoesjes komen van internet.
- **Hoesjes van libretro**: de libretro-thumbnails gebruiken dezelfde No-Intro- en Redump-namen als de libretro-database. GameTDB blijft de bron voor DS, 3DS, GameCube en Wii, zoals in het plan.
- **Kernen** zitten vanaf fase 2 als losse frameworks in de app in plaats van als broncode in het Swift-pakket. iOS laadt die gewoon, omdat ze in de app zitten en mee ondertekend worden.
- **PS1, DS en N64 zonder JIT**: ze draaien met een interpreter. Op een iPhone 14 Pro is dat ruim snel genoeg voor PS1 en DS (zie "Snelheid meten").
- **GameCube en Wii al in fase 3**: het plan had ze in fase 4. Zonder JIT is Dolphin waarschijnlijk te langzaam voor zware spellen; dat moet de meting op de iPhone uitwijzen.
- **PSP** hoort bij fase 3, maar kwam als laatste, na de 3DS.

## Bekende problemen

- **Simulator, eerste spelstart**: heel soms loopt het geluidssysteem van de simulator vast als je na het openen van de app het eerste spel start. De app sluit dan; CoreAudio meldt "RPC timeout. Apparently deadlocked". Dit komt door een race in Apple's audiocode in de simulator. CoreAudio speelt bij het eerste gebruik een eigen systeemklank, precies terwijl de app zijn geluid opzet. De app zet nu eerst de audiosessie op en dan pas de geluidsgraaf, zoals Apple aanraadt. Daarna kwam het in een handvol tests niet meer voor, maar uitsluiten kan ik het niet. Op een echte iPhone draait de audioserver in een eigen proces; daar verwacht ik het niet.
- **Homebrew met een bestaande spelcode** krijgt de titel en het hoesje van dat spel. Het DS-testprogramma had eerst code ATDP, en dat bleek "42 All-Time Classics" te zijn. Het gebruikt nu `####`, de gebruikelijke code voor homebrew.
- **N64-save states zijn groot**: ruim 16 MB per state, vooral het werkgeheugen van de N64.
- **GameCube-save states zijn nog groter**: ongeveer 90 MB per state (Wii nog meer). Ook de auto-save bij stoppen is zo groot. Inpakken op schijf zou veel schelen, maar zit er nog niet in.
- **Dreamcast-snelheid nog niet gemeten op de iPhone**: Dreamcast-spellen liepen op een iPhone 14 Pro iets langzamer dan 1×, omdat Flycasts interpreter de SH4 op 25 MHz liet draaien. Die staat nu op 50 MHz (instelbaar). Of de iPhone 50 of 100 MHz bijhoudt, en of het tekenen dan meekomt, moet een meting met Prestaties tonen uitwijzen.
- **Dreamcast-save states zijn 36 MB**: Flycast vraagt ruimte voor alles wat een state kan bevatten (werkgeheugen, videogeheugen, geluidsgeheugen en 10 MB extra) en zegt niet hoeveel hij ervan gebruikt.

## Nog niet gebouwd

- 3DS: updates en DLC (CIA's die in de NAND moeten worden geïnstalleerd), de New 3DS-stand, de C-stick, ZL en ZR op het scherm, en de bewegingssensor.
- Wii: de Wii Remote zonder Nunchuk (zijwaarts), de Classic Controller en de bewegingssensoren van de iPhone als Wii-bewegingen.
- De C-stick van de GameCube op het scherm.
- Wifi-overdracht (attic.local). Er staat een melding in de app.
- iCloud-synchronisatie. De schakelaar staat uit en is uitgeschakeld.
- Zelf een hoesje kiezen of een ander zoeken.
- Skins, knoppen verslepen, en het aanraakscherm voor de 3DS.
- BIOS-bestanden toevoegen, bijvoorbeeld een echte PlayStation-BIOS voor spellen die met de HLE-BIOS niet goed werken.
- Analoge sticks (DualShock) voor PlayStation, en wisselen van schijf bij spellen met meerdere cd's.
- Trillen (Rumble Pak) bij de N64.
- Chromecast: het geluid naar de tv (het blijft nu op de iPhone, zo'n 0,1 s vóór het beeld), 1080p, en blijven casten bij het volgende spel (nu stopt het als je de speler sluit).

## Demo-cartridge en testprogramma's opnieuw bouwen

```bash
python3 DemoCartridge/build.py "Attic/Resources/Demo/Attic Demo.gba"
```

```bash
python3 TestPrograms/nes.py "TestPrograms/out/Attic Test (NES).nes"
python3 TestPrograms/snes.py "TestPrograms/out/Attic Test (SNES).sfc"
python3 TestPrograms/n64.py "TestPrograms/out/Attic Test (N64).z64"
python3 TestPrograms/ds.py "TestPrograms/out/Attic Test (DS).nds"
python3 TestPrograms/gc.py "TestPrograms/out/Attic Test (GC).dol"
python3 TestPrograms/ps1.py "TestPrograms/out/Attic Test (PS1).exe"
python3 TestPrograms/dc.py "TestPrograms/out/Attic Test (DC).elf"
python3 TestPrograms/psp.py "TestPrograms/out/Attic Test (PSP).pbp" --pspdev /pad/naar/pspdev
```

Wat de testprogramma's laten zien:

- **NES**: met de D-pad beweeg je een blokje; A wisselt de kleuren en piept, B piept lager.
- **SNES**: de achtergrondkleur toont de laatst ingedrukte knop: A blauw, B groen, X wit, Y geel, L paars, R roze, D-pad rood.
- **N64**: een lampje per controllerbit (van links naar rechts A, B, Z, Start, D-pad omhoog, omlaag, links, rechts, twee ongebruikte, L, R, C omhoog, omlaag, links, rechts), fel zolang je de knop vasthoudt en gedimd als hij al eens is ingedrukt. Een geel blokje volgt de stick, en vier lampjes daaronder onthouden of de stick naar links, rechts, omhoog en omlaag is geweest. Het programma tekent met RDP-opdrachten rechtstreeks vanaf de processor en leest de controller via de PIF, dus zonder Nintendo-bootcode of microcode.
- **GameCube**: ATTIC en GC, en een blokje dat knippert zolang de processor draait. Het beeld zit als gegevensblok in het programma en komt bij het laden direct in het videogeheugen (XFB); het programma zet alleen de video-uitgang (VI) aan en draait dan een lus. Knoppen leest het niet.
- **DS**: bovenaan een lampje per knop, onderaan stippen waar je het scherm aanraakt. Start wist de stippen.
- **PS1**: een lampje per knop, fel zolang je hem vasthoudt en gedimd als hij al eens is ingedrukt. Het vlak in het midden licht op zolang je een knop vasthoudt.
- **PSP**: ATTIC PSP, een draaiende kubus die de GPU van de PSP tekent, een lampje per knop (fel zolang je hem vasthoudt, gedimd als hij al eens is ingedrukt) en een stip die de stick volgt. Anders dan de andere testprogramma's is dit C, gebouwd met de open-source PSPSDK: haal pspdev van github.com/pspdev/pspdev (Releases). De macOS-versie verwacht gmp, mpfr, mpc en zstd van Homebrew; zonder Homebrew bouw je die zelf en wijs je de programma's van pspdev er met `install_name_tool` naar. Het programma heeft spelcode ATTC00001: zonder eigen code schrijft de PSPSDK UCJS10041, de code van een bestaand spel.
- **Dreamcast**: ATTIC en DC, en een blokje dat knippert zolang de processor draait. Flycasts BIOS-vervanging laadt het programma (ELF) met het beeld in het geheugen. Het programma zet de framebuffer aan, haalt de video-uitgang uit de stand "zwart" (VO_CONTROL; dat doen spellen zelf, de BIOS-vervanging niet), kopieert het beeld naar het videogeheugen en draait dan een lus. Knoppen leest het niet.

## Snelheid meten

Start de app met de optie `-AtticBenchmark`. Elk spel in de map `Benchmark` van de app (op de iPhone: Bestanden › Attic › Benchmark) draait dan tien seconden zo snel als het kan, zonder beeld en geluid. De uitkomst komt in `Benchmark/results.txt`; daarna sluit de app zichzelf. Meet met een Release-build, want in een Debug-build is de Swift-code van de app veel trager.

Naast een spel kan een save state liggen met dezelfde naam en `.state` (bijvoorbeeld een `auto.state` uit `Saves/<spel>/States`), dan meet je het spelen in plaats van het opstarten. In `<naam>.options` is elke regel een eigen meting met andere kernopties, als `sleutel=waarde` met spaties ertussen, bijvoorbeeld `reicast_sh4clock=100`. Spellen worden herkend zoals bij importeren; schijfsporen (.bin) gaan via hun .cue. Bij een kern met een eigen emulatiethread (Flycast) staat erachter hoe snel het spel volgens zijn geluid liep en hoeveel processortijd de drukste threads per seconde speltijd gebruikten.

Vanaf de Mac een bestand naar de iPhone kopiëren en de meting starten (de UDID van je iPhone geeft `xcrun devicectl list devices`):

```bash
xcrun devicectl device copy to --device <UDID> --domain-type appDataContainer --domain-identifier app.attic --source "TestPrograms/out/Attic Test (PS1).exe" --destination "Documents/Benchmark/Attic Test (PS1).exe"
xcrun devicectl device process launch --device <UDID> --console --terminate-existing -- app.attic -AtticBenchmark
```

Gemeten op een iPhone 14 Pro (iOS 27.0.1, Release-build, 22 oktober 2026):

| Systeem | Testprogramma | Snelheid | Per frame: gemiddeld / langste |
|---|---|---|---|
| GBA | Attic Demo | 66× | 0,3 / 0,6 ms |
| NES | Attic Test (NES) | 57× | 0,3 / 0,4 ms |
| SNES | Attic Test (SNES) | 13× | 1,3 / 2,2 ms |
| DS | Attic Test (DS) | 10,4× | 1,6 / 3,3 ms |
| PS1 | Attic Test (PS1) | 8,7× | 1,9 / 2,4 ms |
| N64 | Attic Test (N64) | 4,3× | 3,9 / 15,3 ms |

De N64 is later gemeten, vlak na een nieuwe installatie; de andere systemen haalden in die ronde 8 tot 25% minder dan hierboven. Het budget is 16,7 ms per frame (60 frames per seconde). De testprogramma's laten de processors het hele frame doorrekenen, het zwaarste deel zonder JIT. Ze tekenen alleen geen 3D en spelen weinig geluid. Echte PS1- en DS-spellen met veel 3D kosten meer; met deze marge zou dat ruim moeten passen, maar dat is nog niet gemeten.

## Bronnen en licenties

Zie ook Instellingen › Emulators en licenties in de app; daar staan ook de kleinere bibliotheken in de kernen (SameBoy, libco, nes_ntsc, FreeBIOS, Teakra, FatFs, libchdr, GLideN64, libpng en andere) met hun licentietekst.

| Onderdeel | Bron | Licentie |
|---|---|---|
| mGBA | github.com/libretro/mgba @ 7a12d6d | MPL 2.0 |
| Nestopia UE | github.com/libretro/nestopia @ 06a8949 | GPL 2 of later |
| bsnes | github.com/libretro/bsnes @ 63ee22f | GPL 3 (libco en nall: ISC) |
| melonDS | github.com/libretro/melonDS @ 66b5d26 | GPL 3 |
| PCSX ReARMed | github.com/libretro/pcsx_rearmed @ c881679 | GPL 2 of later |
| Mupen64Plus-Next | github.com/libretro/mupen64plus-libretro-nx @ 12edd2c | GPL 2 of later; GLideN64 GPL 2 (delen MIT, BSD en LGPL 3) |
| Dolphin | github.com/libretro/dolphin @ 5466da3, met de Cached Interpreter uit github.com/Provenance-Emu/dolphin-ios-jitless @ 8fc454c | GPL 2 of later (bibliotheken MIT, BSD, zlib, Apache 2.0 en LGPL) |
| Flycast | github.com/flyinghead/flycast @ fa9d39a | GPL 2; xBRZ GPL 3 (bibliotheken BSD, zlib en Boost) |
| Azahar | github.com/azahar-emu/azahar @ 219d743 (2126.2) | GPL 2 of later (bibliotheken MIT, BSD, Boost, Apache 2.0, LGPL en GPL) |
| MoltenVK | github.com/KhronosGroup/MoltenVK, release v1.4.1 | Apache 2.0 |
| PPSSPP | github.com/hrydgard/ppsspp @ fa50bb1 (v1.20.4) | GPL 2 of later; FFmpeg LGPL 2.1; xBRZ GPL 3 (bibliotheken MIT, BSD en Apache 2.0) |
| libretro-database | github.com/libretro/libretro-database @ 12c21cf (bewerkt tot `GameDB.sqlite`) | CC BY-SA 4.0 |
| libretro.h | uit mGBA (RetroArch-team) | MIT |
| LZMA SDK | github.com/ip7z/7zip @ b88c6bc (map `C`) | Publiek domein |
| inih | uit mGBA | BSD 3-clause |
| Bricolage Grotesque, Inter, JetBrains Mono | github.com/google/fonts | SIL OFL 1.1 |

Het laadeffect bij het toevoegen is de decode-stijl van ascii-reveal (github.com/quanhoangindex/ascii-reveal, MIT, Quan Hoang), opnieuw gemaakt in SwiftUI; er is geen code uit overgenomen. Toch staat het met zijn licentie in de app (Instellingen › Emulators en licenties, `Resources/Licenses/MIT-ascii-reveal.txt`).

Voor de Chromecast is het Cast-protocol nagebouwd aan de hand van openscreen (chromium.googlesource.com/openscreen, BSD 3-clause), Google's open beschrijving en implementatie van Cast Streaming. Er is geen code uit overgenomen, en van Google's gesloten Cast-bibliotheek zit niets in de app.

Hoesjes zitten niet in de app: de app haalt ze op je iPhone op bij GameTDB (art.gametdb.com) en de libretro-thumbnails (thumbnails.libretro.com), en ze blijven op je iPhone.

mGBA valt onder de MPL 2.0. Nestopia, bsnes, melonDS, PCSX ReARMed en Mupen64Plus-Next vallen onder de GPL: bsnes en melonDS onder versie 3, Nestopia, PCSX en Mupen64Plus onder "versie 2 of later", en dat gaat samen met versie 3. GLideN64, het N64-beeld in Mupen64Plus-Next, staat onder "versie 2" zonder "of later"; dat gaat strikt genomen niet samen met de GPL 3 van bsnes en melonDS in één app. Voor eigen gebruik via Xcode speelt dat niet. Verspreid je de app ooit, dan moet je de volledige broncode beschikbaar maken, de app zelf inbegrepen (zoals Delta doet), en dit eerst uitzoeken. Verspreiden via de App Store is met GPL-code omstreden; VLC werd er daarom in 2011 uit gehaald. De spellendatabase komt uit de libretro-database (CC BY-SA 4.0): naamsvermelding staat in de app, en de bewerkte database valt ook onder CC BY-SA 4.0.
