# MKS-50 für iOS

Ein nativer iOS-Software-Synthesizer, der die Architektur des **Roland MKS-50** (Rack-Version des Alpha Juno) nachbildet. Er läuft als **Standalone-App** und als **AUv3-Instrument-Plugin** in GarageBand, AUM, Cubasis, Logic Pro für iPad, Drambo usw.

> Unabhängiges Projekt, nicht mit der Roland Corporation verbunden. „MKS-50“ und „Alpha Juno“ dienen nur als Beschreibung der nachgebildeten Architektur.

## Funktionen

| Bereich | Umsetzung |
|---|---|
| **DCO** | 4 Pulse-, 6 Sägezahn- und 6 Sub-Wellenformen, nachgebaut wie im Alpha-Juno-DCO: Rampe bzw. Rechteck, „zerhackt“ (AND) durch Rechtecke +1 und +3 Oktaven höher bzw. auf Sub-Oktaven. Range 4'/8'/16'/32' (SysEx-Reihenfolge), Sub-Level, Noise. Alle Wellen phasenstarr über einen Teiler (wie die Hardware) und an jeder Kante mit PolyBLEP bandbegrenzt |
| **PWM** | PW/PWM-Tiefe und eigene PWM-Rate (Rate 0 = manuelle Pulsbreite) |
| **HPF** | 4 Stufen: Bass-Boost, flach, 240 Hz, 720 Hz |
| **VCF** | Resonanter 24-dB-Tiefpass (IR3109-Stil, Zero-Delay-Feedback), selbstoszillierend, Env/LFO/Key-Follow/Aftertouch-Modulation |
| **VCA** | ENV- oder GATE-Modus, jeweils mit/ohne Velocity („Dynamics“) |
| **ENV** | Alpha-Juno-Hüllkurve mit 4 Zeiten und 3 Pegeln (T1/L1, T2/L2, T3/L3, T4) plus Key-Follow; Env-Modi normal/invertiert, mit/ohne Dynamics für DCO und VCF |
| **LFO** | Rate und Delay (Einblendung pro Tastenanschlag). Wellenformen: **Dreieck** (wie das Original, Standard), Sinus, Säge auf/ab, Rechteck, Sample & Hold, weicher Zufall. **Tempo-Sync** mit Notenwerten von 1/32 bis 4 Takte (im Plugin phasenstarr zur Song-Position des Hosts, in der App zum BPM-Regler) und **Key-Sync** (LFO startet bei neuem Tastenanschlag von vorn) |
| **Chorus** | Juno-artiger Stereo-BBD-Chorus mit Rate-Regler |
| **Patch** | Key-Modi **Poly / Chord / Mono / Unison**, 16 Chord-Memory-Speicher (per „LEARN CHORD“ vom angeschlossenen MIDI-Keyboard, CHORD-Regler stimmt gehaltene Akkorde live um), Portamento **OFF / ON / AUTO**, Hüllkurven-Trigger MULTI / LEGATO, Bender-Range, Mod-Sensitivity, Key Shift, Volume |
| **Arpeggiator** | Tempo-synchron, UP / DOWN / UP-DN / RAND / ORDER, 1–4 Oktaven, Rate 1/32 bis 4/1, Gate, HOLD; im CHORD-Modus spielt er die Akkordtöne einstimmig nacheinander |
| **Step-Sequencer** | 16 Steps mit Akzent und Tie, transponiert vom gehaltenen Ton, taktgenau; **Zufallsgenerator** in den Stilen KRAFT, ROTHER, ROBOT und ACID, *VARY* und *G.VAR*-Groove für die Notenlängen |
| **Loop-Recorder** | Nur App: nimmt 1/2/4/8 Takte sample-genau auf, legt Delay-/Hall-Fahnen nahtlos auf den Loop-Anfang und speichert 24-Bit-WAV (Dateien-App, Teilen) |
| **Stimmen** | 6 Stimmen (wie das Original), Voice Stealing, Sustain-Pedal |
| **TAL-Pha-Extras** | Pulse-Detune (±12 HT), Pulse-Hard-Sync und Env→Pulse-Pitch (Sync-Sweeps), **Voice Drift** („Voice Calibration“: feste Toleranzen pro Stimme bei Tonhöhe, Cutoff und Hüllkurvenzeiten plus langsames Wandern), **Stereo-Unison** mit allen 6 Stimmen, Detune-Spread und Panorama |
| **MIDI** | CoreMIDI (USB, Netzwerk, **Bluetooth LE MIDI**), virtueller Port „MKS50 Synth“ für andere Apps, Empfangskanal Omni/1–16, Pitch Bend, Mod Wheel (CC1), Aftertouch, Sustain (CC64), Portamento (CC5/CC65), Program Change, **MIDI-CC-Learn** für beliebige Parameter |
| **SysEx** | Empfang von MKS-50/Alpha-Juno-**Tone-Dumps (APR)** und **Einzelparameter (IPR)**, z. B. vom PG-300 oder einem Editor; Import/Export von `.syx`-Dateien; Senden des aktuellen Sounds an ein echtes MKS-50 |
| **Presets** | 64 eigene Factory-Sounds in **Kategorien** (Bass, Lead, Sequence, **Electro Zaps** (ZAP, ZAP CLASSC, LASER, PEW PEW, RISE ZAP, SYNC ZAP, NOISE ZAP, RES ZAP, DUB ZAP), **Strings im JX-8P-Stil** (JX STRINGS, JX ENSEMBL, STR STAB, DARK STR, SWEEP STR, BRIGHT STR, STR CHORD, SLOW STR), Stab, Keys, Strings & Brass, Pad, FX & Perc; im Preset-Menü als Untermenüs mit Symbol, das LCD zeigt die Kategorie). Darunter LFO-Sequenzen mit Tempo-Sync und Sample & Hold (S&H BLEEP, S&H BASS, OCT BOUNCE, SAW SWEEP, TRIPLETZAP, GATE CHORD, WOBBLE 1/8, COMP TALK, S&H NOISE, DRIFT PAD, VIBE LEAD). Außerdem Klassiker (Hoover, Juno Brass, Strings, House Stab …) und eine **Electro-Funk-Bank** im Geist von Kraftwerk und Anthony Rother (ROBO BASS, NUMBERS, CALCULATR, TRANS EURO, ROBOT VOX, AUTO BASS, ELEC STAB, ACID ELEC, MACHINE PD, ZAP, ELEC HAT, BOOM 808, SPACE LEAD, ROBO CHOIR). Dazu Arp- und Sequencer-Sounds (ARP ROBOT, ARP UPDOWN, ARP BASS, SEQ KRAFT, SEQ ROTHER) und die TB-303-artige **ACID LINE**. Eigene Sounds speicherst du mit einem Tipp unter *My Presets*; in der App in einem eigenen Speicher, im Plugin über das AUv3-Preset-System des Hosts |
| **FX** | **Distortion** (OD / DIST / RAT mit Drive, Tone, Level, Mix) vor dem Chorus. Danach ein **organisches Delay** im Geist des Erica Synths Echolocator: 0,5 ms bis 2 s oder Notenwert mit Tempo-Sync, unter etwa 4 ms wird es zum Kammfilter-, Flanger- oder Karplus-Resonator. Feedback geht bis 115 %, über 100 % schaukelt es sich als Dub-Delay auf und wird weich begrenzt. Im Feedback-Weg liegen Ton-Filter und warme Sättigung, *MOD* fügt Wow, Flutter und Drift hinzu wie Band oder Eimerkette. Der rechte Kanal ist etwas länger für Breite, Zeitänderungen gleiten mit Tonhöhen-Bending, dazu Ping-Pong. Das **Reverb** ist im Geist des Eventide Black Hole gebaut, kann aber auch kurze Räume: *SIZE* reicht vom kleinen Raum bis zum riesigen Raum mit Pre-Delay bis 60 ms, *DECAY* von 0,15 s bis 60 s, *MOD* moduliert alle acht Hall-Linien für eine schwebende Fahne, *DAMP* macht es dunkler. *TYPE* wählt den Algorithmus: *SPACE* (riesig und moduliert, wie oben beschrieben), *ROOM* (realistischer Raum mit frühen Reflexionen, die mit SIZE mitwachsen, nach dem Prinzip des TC Electronic VSS3, das Anthony Rother laut seinen Production Notes in fast jedem Track nutzt) oder *PLATE* (sofort dicht und hell wie ein Plattenhall). Technik: 8-Kanal-FDN mit Diffusoren |
| **UI** | Kompaktes SwiftUI-Panel im Stil von Teenage Engineering (OP-XY / OP-1): fast schwarze, flache Flächen, farbige Encoder, Monospace-Beschriftung in Kleinbuchstaben, MKS-50-Blau und Roland-Rot als Akzente. Wellenform-Buttons zeigen die echte Wellenform, dazu Symbole für Hüllkurven-Modi, Hochpass und Key-Modi. Seiten: OSC · MOD · FILTER · ENV · AMP · FX · ARP · SEQ · PATCH · EXTRA. Sektionen ordnen sich nach Bildschirmbreite an, auf dem iPhone im **Quer- und Hochformat**. Statt Tastatur gibt es **einen großen Spiel-Button** mit zuweisbarer MIDI-Note (±Halbton/±Oktave, auch während er gedrückt ist, oder *LEARN* vom Keyboard), *HOLD* und Schnellschaltern für ARP und SEQ. Große Wertanzeige beim Drehen, VoiceOver-Unterstützung |

Die Parameteradressen 0–35 entsprechen exakt den Tone-Parameternummern des MKS-50. Damit sind die SysEx-Nachrichten direkt kompatibel, und Host-Automation verwendet dieselben Wertebereiche wie die Hardware (0–127 bzw. diskrete Schalter).

## Vorbilder aus der Plugin-Welt – und wie sie für iOS angepasst wurden

- **TAL-Pha (TAL Software)** ist die Hauptvorlage für den Klang: eine Alpha-Juno-2-Emulation, für die das MKS-50 als Referenz diente. Übernommen wurden die Architektur (ein PWM-fähiger DCO mit Sub → HPF → 24-dB-Tiefpass mit verstärkter Resonanz für Selbstoszillation), die Erweiterungen des Pulse-Teils (Detune, Modulation, Sync), die Voice-Calibration-Idee (leichte Abweichungen pro Stimme, damit es nach Analog-Hardware klingt) und der Stereo-Unison. TAL-Pha ist Closed Source. Hier wurde **kein Code übernommen**, nur das öffentlich beschriebene Konzept, umgesetzt mit eigener DSP. Arpeggiator, Delay und Reverb gibt es inzwischen (eigene Umsetzung). MPE, Mikrotuning und der EQ von TAL-Pha sind noch nicht enthalten.
- **Wellenformen**: Modell des DCO-Chips MB87123 nach der Analyse von ErroneousBosh (alphaOsc, aus Service-Manual und KVR-Thread „Alpha Juno-2 pwm sawtooth“), deckungsgleich mit dem Emulator june-21: Ein 8-Bit-Rampenzähler wird mit Zählerbits UND-verknüpft. Pulse 1 = Rechteck, Pulse 2 = fester 25-%-Puls, Pulse 3 = PWM (einseitig 50 % → 0 %). Saw 2 = Rampe · Rechteck +1 Okt., Saw 3 = Rampe · PWM-Gate (+1 Okt.), Saw 4 = Rampe · Rechteck +3 Okt., Saw 5 = beides. Sub 0 = Rechteck −1 Okt., Sub 1 = 25 % −1 Okt., Sub 2/3 = −1 Okt. gehackt mit +1/+2 Okt., Sub 4 = −2 Okt., Sub 5 = 25 % −2 Okt. Die Gates sind wie im Zähler phasengleich zur Rampe (offen in der oberen Hälfte). *Sub Level 0* schaltet den Sub aus.

- **Apple-AUv3-Instrument-Vorlage**: Eine Audio-Unit-Klasse (`MKS50AudioUnit`) wird sowohl in der App (in-process über `AUAudioUnit.registerSubclass`) als auch in der Extension genutzt. Die App ist damit nur ein „Host“ ihres eigenen Plugins – genau wie Desktop-Plugins Standalone und VST/AU aus einem Kern bauen.
- **Juno-/Alpha-Juno-Emulationen (z. B. TAL-U-NO-LX, Dexed-artige Editoren mit SysEx-Unterstützung)**: Parameter in Hardware-Einheiten, SysEx-kompatible Tone-Daten, Preset-Import per `.syx`.
- **Echtzeit-Regeln aus JUCE/iPlug**: Im Render-Thread wird nichts allokiert und nie blockiert. MIDI vom UI-/CoreMIDI-Thread kommt über eine Queue, die der Audio-Thread nur mit `os_unfair_lock_trylock` liest. Parameter-Events des Hosts werden sample-genau verarbeitet.
- **iOS-spezifisch**: große Touch-Ziele (≥ 44 pt) statt Maus-Bedienung, Bluetooth-MIDI-Pairing mit Apples Standard-Dialog, Audio-Session mit 5-ms-Puffer und Hintergrund-Audio, Wiederanlauf nach Unterbrechungen und Routenwechseln, Dateien über die Dateien-App, Layout für Quer- und Hochformat auf iPhone und iPad.

## Effizienz (ohne Klangeinbußen)

Jede Optimierung wurde gegen die vorherige Referenz geprüft (Python-Port, Sample-Vergleich):

- **Leerlauf kostet nahezu nichts:** Sind alle Stimmen verklungen, die Effekt-Fahnen 100 ms lang unter −100 dBFS und Arp/Sequencer ohne gehaltene Tasten, rechnet die Engine nichts mehr und meldet dem Host `OutputIsSilence`.
- **Nur aktive Stimmen** werden berechnet. Modulation und Filterkoeffizienten laufen mit Kontrollrate (alle 16 Samples), alle Parameterkurven (`powf`/`expf`) werden **einmal pro Block für alle Stimmen** berechnet.
- **Oszillator:** Kantensuche ohne Rundung, mit Wiederverwendung der lokalen Phasen. Die volle Kantenhöhen-Messung läuft nur innerhalb eines Samples um eine Kante. Das Ergebnis ist identisch zur Referenz (Abweichung < 10⁻⁶).
- **Hüllkurve:** rekursive Exponentialkurve statt `expf` pro Sample (max. Abweichung 2·10⁻⁴ ≈ −74 dB, unhörbar).
- **HPF** wird in Stellung „flat“ übersprungen (bitgleich, da Bypass).
- **Echtzeit-sicher:** keine Allokation und kein Blockieren im Audio-Thread; MIDI vom UI läuft über eine Queue mit `trylock`.
- **UI:** Das Panel fragt die Engine nur ab, solange es sichtbar ist. Im Hintergrund pausiert die App die Audio-Engine, wenn kein MIDI-Gerät verbunden ist.
- Release- und Debug-Build sind mit `-O` optimiert, Release zusätzlich mit Whole-Module-Optimization.

## Authentizität – was nachgebildet ist

Abgeglichen mit dem MB87123-Bit-Modell, der PG-300/MKS-50-SysEx-Tabelle und den am echten Juno-2 gemessenen Tabellen des june-21-Emulators (dessen Autor schreibt, die Messungen schwankten etwas). Zahlen, für die es keine Quelle gibt, sind als Annahme markiert.

- **DCO:** digitale Zähler-Logik des Alpha Juno (siehe oben), phasenstarr, bandbegrenzt. **RANGE** in Hardware-Reihenfolge 4' / 8' / 16' / 32' (SysEx-kompatibel).
- **PWM:** PW-Wert 0–127 wird wie im Chip mit den unteren 7 Zählerbits verglichen; eigener PW-LFO (Dreieck, 0,02–20 Hz nach Tabelle), PWM RATE 0 = manuelle Breite.
- **Pegel:** Sub-Level in 6-dB-Stufen (0 / −12 / −6 / 0 dB), Noise in drei Stufen (Annahme).
- **HPF:** 0 = Bassanhebung (Shelf, etwa +3 dB bei 70 Hz), 1 = flach, 2/3 = 1-Pol-Hochpass (6 dB/Okt.) bei etwa 225 / 700 Hz, wie Juno-106.
- **VCF:** 24 dB/Okt., Cutoff 100 Hz · 2^(Wert/12 − 3,2) (etwa 11 Hz–16 kHz, eine Oktave pro 12 Schritte), Env-, LFO- und Key-Follow-Tiefe auf derselben Skala. Wie beim Original **keine Selbstoszillation**: Die Resonanz klingelt stark, und der Bass wird mit steigender Resonanz dünner.
- **Hüllkurve:** T1/T2 = 0,354 s · 2^((Wert − 64)/10) (4 ms … 27 s), T3 (0,09 … 38 s) und T4 (7 ms … 39 s) nach gemessenen Tabellen; Attack linear, die übrigen Segmente exponentiell.
- **LFO:** Dreieck, Rate etwa 0,02–65 Hz nach Tabelle, Delay exp(Wert/14,2 − 3)/10 s; DCO-LFO-Tiefe bis etwa ±3,3 Halbtöne.
- **VCA:** GATE-Modus mit sehr schnellem Einsatz und kurzem Declick-Release.
- **Chorus:** zwei MN3009-Eimerketten, mono rein, stereo raus mit gegenphasiger Modulation; Rate nach Tabelle 0,01–10 Hz. Grundverzögerung und Tiefe sind nicht dokumentiert (Annahme 3,5 ± 1,9 ms).
- **Stimmstabilität:** Die DCOs sind quarzstabil. *Voice Drift* steht deshalb standardmäßig niedrig (8) und kann für „Vintage“ erhöht werden.
- **Offen:** Hüllkurven-Update-Rate der CPU, exakte Mixer-Pegel und der genaue VCF-Aufbau (laut Service-Manual zwei State-Variable-Stufen) sind nicht dokumentiert.

## Projektstruktur

```
MKS50.xcodeproj         Xcode-16-Projekt (synchronisierte Ordner)
Shared/                 wird in App UND Extension kompiliert
  DSP/                  DCO, LadderFilter, Envelope, Chorus, Effects (Distortion, Delay, Reverb),
                        Arpeggiator, StepSequencer, LoopRecorder, SynthEngine
  AU/                   MKS50AudioUnit (AUv3, Parameterbaum, Presets, State)
  Model/                Parameter (MKS-50-Nummerierung), ToneData + SysEx, Presets, Chords,
                        SequenceGenerator (Zufalls-Patterns)
  UI/                   SwiftUI-Panel (Seiten), Regler, Spiel-Button, Sequencer-Grid, ViewModel
MKS50App/               Standalone-App: AVAudioEngine-Host, CoreMIDI, Einstellungen, Loop-Recorder
MKS50AU/                AUv3-Extension: AudioUnitViewController (Factory + UI)
Config/                 Info.plists (Hintergrund-Audio, AudioComponents)
```

Signalfluss pro Stimme: `DCO → HPF → VCF (24 dB) → VCA`, danach Summe → DC-Blocker → Distortion → Chorus (Stereo) → Delay → Reverb → Soft-Limiter. Arpeggiator und Sequencer erzeugen ihre Noten vor den Stimmen und spielen über den normalen Notenweg (Key-Mode, Portamento, Hüllkurven-Trigger).

## Bauen & Installieren

Voraussetzungen: macOS mit **Xcode 16** oder neuer, iPhone/iPad mit iOS 16+, eine (kostenlose) Apple-ID.

```bash
git clone https://github.com/robtron-byte/Mks50-iOS-.git
cd Mks50-iOS-
./setup.sh
```

`setup.sh` erledigt Folgendes:
1. Prüft Xcode und schließt bei Bedarf die Erstinstallation ab.
2. Erkennt deine Team-ID am Entwickler-Zertifikat im Schlüsselbund oder fragt danach.
3. Legt ein eigenes Bundle-ID-Präfix fest und speichert beides in `Config/Signing.local.xcconfig` (nicht im Git).
4. Macht einen Testbuild ohne Signing. Bei Fehlern zeigt es die Meldungen an, das komplette Log steht in `build.log`.
5. Öffnet das Projekt in Xcode und zeigt die letzten Schritte an: iPhone wählen, **Cmd+R**.

Auf dem iPhone beim ersten Start den Entwicklermodus einschalten (*Einstellungen → Datenschutz & Sicherheit*) und dem Entwickler vertrauen (*Allgemein → VPN & Geräteverwaltung*). Mit kostenloser Apple-ID läuft die App 7 Tage und lässt sich dann per Cmd+R neu installieren.

Die AUv3-Version erscheint nach der Installation in Hosts unter *Robtron → MKS50 Synth*.

Hinweis: Auch der Debug-Build ist mit `-O` optimiert, weil Swift-DSP ohne Optimierung auf dem Gerät Aussetzer verursachen kann.

## Bedienung

- **Regler**: hoch/runter oder links/rechts ziehen; Doppeltipp setzt den Standardwert. Die Farbe zeigt die Funktion, auf jeder Seite gleich: **Blau** = Klangquelle (Oszillator, Pulse, Stimmen, Stimmung), **Grün** = Modulation (LFO, Mod-Tiefen, Aftertouch), **Orange** = Filter und Verzerrung, **Weiß** = Hüllkurve, Lautstärke und Spielhilfen, **Violett** = Zeit und Effekte (Delay, Reverb, Chorus, Tempo, Arp, Sequencer). Der Wert wird als Kranz aus runden Leuchtpunkten angezeigt.
- **Presets**: Tippen auf die Preset-Anzeige öffnet die Liste nach Kategorien; Pfeile blättern durch die Factory-Sounds. Läuft ARP oder SEQ, behält ein Preset-Wechsel das Muster bei, nur der Klang wechselt.
- **Spiel-Button**: Gedrückt halten spielt die zugewiesene Note. Die Pfeile ändern sie um einen Halbton bzw. eine Oktave. *MIDI LEARN* antippen und eine Taste am Keyboard spielen übernimmt diese Note. Mit *HOLD* bleibt der Ton nach dem Antippen stehen, bis du erneut tippst. Transponierst du, während der Ton klingt, wechselt er gebunden zur neuen Note (mit Portamento *AUTO* gleitend).
- **MIDI-CC-Learn**: In der Toolbar das Schieberegler-Symbol antippen. Jeder Regler zeigt jetzt seine CC-Nummer. Regler antippen (er wird markiert) und am externen Controller einen Knopf oder Fader bewegen, fertig. Danach den nächsten Regler antippen oder mit *DONE* beenden. *REMOVE CC* löscht die Zuordnung des gewählten Reglers. In den Einstellungen gibt es eine Liste aller Zuordnungen. Die Zuordnungen gelten unabhängig vom Preset und funktionieren auch im Plugin ohne geöffnete Oberfläche. App und Plugin speichern sie getrennt, weil iOS-Extensions eigene Einstellungen haben. Für eine gemeinsame Liste bräuchte es eine App Group, die du mit deinem Developer-Team einrichtest. Mehrere Plugin-Instanzen teilen sich ihre Liste. Ein CC steuert genau einen Parameter, Schalter springen stufenweise. CC 120–127 (Channel-Mode-Messages) sind nicht belegbar. Eigene Zuordnungen haben Vorrang vor den festen CCs (1 Mod, 5/65 Portamento, 7 Volume, 64 Sustain).
- **Hüllkurven-Tempo** (ENV-Seite, *SPEED* ORIG / SNAP): *ORIG* nutzt die am Juno-2 gemessenen Zeiten, die kürzeste Attack liegt dort bei etwa 4 ms. *SNAP* verkürzt nur die kleinsten Einstellungen (Werte unter 24, bei 0 auf ein Viertel, z. B. T1 = 1 ms), für knackigere Plucks und Bässe. Das ist eine bewusste Abweichung vom Original. Anzeige und Regler zeigen die tatsächliche Zeit.
- **Hüllkurven-Trigger** (ENV-Seite, *TRIGGER*): Gilt für MONO, UNISON und CHORD. *MULTI* (Standard) startet die Hüllkurve bei jeder neuen Note neu, auch wenn sich Noten überlappen, wie bei Sequenzen aus einer DAW oder einem Sequencer. *LEGATO* startet sie nur neu, wenn vorher keine Taste gehalten war. Gebundene Noten gleiten dann ohne neuen Anschlag, wie bei Acid-Linien.
- **Chord Memory**: Key-Mode auf CHORD stellen, Akkord auf dem MIDI-Keyboard halten, auf der PATCH-Seite *LEARN CHORD* tippen. Die Akkorde werden mit dem Preset gespeichert.
- **Arpeggiator** (Seite *ARP*, Schnellschalter *ARP* neben der Spieltaste): Er läuft tempo-synchron zur internen Clock bzw. zum Host-Tempo. *MODE* UP, DOWN, UP/DN, RAND oder ORDER (Spielreihenfolge), *OCTAVES* 1–4, *RATE* 1/32 bis 4/1 inklusive Triolen und punktierter Werte, *GATE* 5–100 %. Mit *HOLD* läuft das Muster nach dem Loslassen weiter, ein neuer Akkord ersetzt es. Der Arp spielt durch den gewählten Key-Mode (POLY, MONO, UNISON, CHORD), auch der Loop-Recorder startet mit der ersten Arp-Note.
- **Step-Sequencer** (Seite *SEQ*, Schnellschalter *SEQ*): 16 Steps, die vom gehaltenen Ton aus transponiert werden und immer am Takt ausgerichtet sind. *NEW* erzeugt ein zufälliges Pattern im gewählten Stil: *KRAFT* (mechanische Motive mit Oktavsprüngen und transponierter Antwort), *ROTHER* (dunkle, synkopierte Phrygisch-Basslines mit Akzenten), *ROBOT* (sparsame, hohe Bleeps) oder *ACID* (dicht, mit Ties und Akzenten). *VARY* verändert ein bis zwei Steps. Im Grid schaltest du mit *EDIT NOTE* Steps per Tipp an oder aus und änderst die Tonhöhe durch Ziehen nach oben oder unten. Mit *ACC* setzt du Akzente, mit *TIE* bindest du einen Step an den nächsten. *G.VAR* blendet von der festen *GATE*-Länge zu einem Groove (0 % = alle Steps gleich lang). Ein Groove-Muster aus fünf Längen (staccato, kurz, mittel, voll und legato, das gebunden in den nächsten Step übergeht und mit Portamento *AUTO* gleitet) wiederholt sich pro Viertel, das letzte Viertel des Takts bekommt eine Variante als Phrasen-Ende. Dazu liest es den Pattern: Noten vor einer Pause klingen aus, Akzente werden länger, Oktavsprünge nach oben werden kurze Bleeps. Der Groove ändert sich mit *NEW* oder *VARY*.
- **Pattern-Bank** (SEQ-Seite, *BANK*): Acht Speicherplätze für Sequenzen. Ein Tipp auf einen leeren Platz oder *SAVE* plus Tipp speichert die aktuelle Sequenz (Steps, Länge, Rate, Gate, G.VAR). Ein Tipp auf einen belegten Platz spielt ihn live: Läuft der Sequencer, blinkt der Platz und übernimmt am Ende der laufenden Sequenz, sodass der Wechsel im Takt passiert. Läuft er nicht, wechselt er sofort. Gedrückt halten öffnet *Speichern* und *Löschen*. Die Plätze sind auf dem Gerät gespeichert und bleiben beim Preset-Wechsel erhalten.
- **Distortion** (FX-Seite, *DIST*): Verzerrer vor Chorus, Delay und Hall. Der Clipper läuft mit 2-fachem Oversampling (47-Tap-Halbband-Filter, etwa −70 dB), damit auch harte Einstellungen nicht „digital“ kratzen. Der trockene Anteil wird um dieselben 24 Samples verzögert, sodass *MIX* nie kammfiltert. Ein Hochpass vor dem Clipper hält den Bass sauber. *OD* ist ein zweistufiger, asymmetrischer Röhren-Overdrive, *DIST* ein Clipper mit weichem Knie und Mitten-Schub, *RAT* ein High-Gain-Dioden-Fuzz. *TUBE* ist eine warme Röhrensättigung mit geraden Obertönen und sanfter Kompression. Vorbild ist die SPL Kultube, die Anthony Rother laut den DEKATRON-Production-Notes im Master-Ausgang seines Pults einsetzt; ein Distortion-Plugin nennt er dort nicht. *DRIVE* regelt die Stärke, *TONE* die Höhen danach, *LEVEL* die Ausgangslautstärke und *MIX* die Mischung mit dem trockenen Signal.
- **Schnell speichern**: Das Speichern-Symbol (Pfeil in die Ablage) in der Toolbar sichert den aktuellen Sound mit einem Tipp als User-Preset. Der Name entsteht automatisch aus dem Sound-Namen und der nächsten freien Nummer (z. B. *SEQ KRA 01*), nichts wird überschrieben. Unter *Save Preset As…* im Datei-Menü vergibst du selbst einen Namen. Gesicherte Sounds findest du im Preset-Menü in der Kategorie *My Presets*.
- **Portamento AUTO** (PATCH-Seite, *PORTAMENTO* OFF / ON / AUTO): Bei *AUTO* gleitet der Ton nur zwischen gebundenen, überlappend gespielten Noten. Einzeln angeschlagene Noten springen. Im Sequencer gleiten so nur die mit *TIE* gebundenen Steps, wie Acid-Slides.
- **Arp im CHORD-Modus**: Der Arpeggiator spielt die Töne des gewählten Akkords einstimmig nacheinander.
- **Hochformat**: Auf dem iPhone passt sich die Oberfläche an, wenn du das Gerät hochkant hältst.
- **Loop-Recorder** (nur App): In der Toolbar den Aufnahme-Kreis antippen, dann erscheint die Recorder-Leiste. Dort wählst du *BARS* (1/2/4/8 Takte, 4/4), *START* (*NOTE* startet mit der ersten gespielten Note, *BAR* auf dem nächsten Taktanfang der internen Clock) und das Tempo (*BPM*). Danach *REC* antippen und spielen. Aufgenommen wird sample-genau exakt die gewählte Taktlänge. Mit *TAILS* nimmt der Recorder zusätzlich 4 s Ausklang auf und legt Delay- und Hall-Fahnen auf den Loop-Anfang, sodass die Schleife nahtlos weiterläuft. Gespeichert wird eine 24-Bit-Stereo-WAV in *Dateien › Auf meinem iPhone › MKS50 › Recordings*. Über das Wellen-Symbol öffnest du die Liste mit Loop-Vorschau, Teilen (AirDrop, DAW) und Löschen (wischen).
- **MIDI-Einstellungen** (Zahnrad): Unter *Inputs* und *Outputs* schaltest du jeden Port per Tipp an oder aus (Häkchen). Die Auswahl bleibt gespeichert, neue Geräte sind automatisch an. Andere Apps (Sequencer, AUM, DAWs) spielen den Synth über den virtuellen Eingang *MKS50 Synth*. Dazu in der anderen App *MKS50 Synth* als MIDI-Ausgang wählen. *Network MIDI (Wi-Fi)* macht das iPhone für einen Mac sichtbar (*Audio-MIDI-Setup › Netzwerk*). *Run in Background* (Standard: an) lässt den Synth weiterspielen, während du in einer anderen App bist.
- **MIDI-Clock-Sync** (Einstellungen › *Sync to MIDI Clock*): Der Synth folgt dann der MIDI-Clock (24 ppqn) eines eingeschalteten MIDI-Eingangs oder einer anderen App, die an *MKS50 Synth* sendet. Er übernimmt Tempo, *Start*, *Continue*, *Stop* und *Song Position*. Arpeggiator und Sequencer laufen nur, während die Quelle spielt. *Start* beginnt beim ersten Step, *Stop* beendet die Noten. Synchronisierte LFOs, Delays und der Loop-Recorder (*START BAR*) laufen im Takt der Quelle. Die Recorder-Leiste zeigt statt BPM das gemessene Tempo mit „ext ▶“ bzw. „ext ■“. Im Plugin folgt der Synth wie bisher dem Host-Transport.
- **Hardware-MKS-50**: In den Einstellungen den MIDI-Kanal wählen; der Papierflieger sendet den aktuellen Tone als APR-SysEx. Tone-Dumps vom Gerät werden live übernommen.

## Grenzen / Ideen für später

- Saw 2–5 und Sub 0–5 folgen der dokumentierten Chop-Logik. Pulse 3 und die genaue Zuordnung von Sub 1–3 sind in den Quellen widersprüchlich und deshalb angenähert. Zum Feinabgleich: `DCOSettings.configure` in `Shared/DSP/DCO.swift`.
- Bulk-Dumps (BLD, 64 Töne gepackt) werden noch nicht gelesen, nur APR-Einzel-Tones (auch mehrere in einer Datei).
- In der AUv3-Extension wird SysEx vom Host nicht ausgewertet (Parameter-Automation funktioniert vollständig).
- Der Parameterspeicher (`Param.storageSize`) hat 192 Plätze, belegt sind die Adressen bis 127. State und Presets speichern nach Adresse, ältere Sounds bleiben ladbar.
- Im Plugin mit gestopptem Host-Transport bleibt die Song-Position stehen; Arp und Sequencer halten dann ihren Step.
- Mögliche Erweiterungen: MPE, Oversampling des Filters, Patch-Ebene (Patch-APR), Ableton Link für Clock und LFO.
