# MKS-50 für iOS

Ein nativer iOS-Software-Synthesizer, der die Architektur des **Roland MKS-50** (Rack-Version des Alpha Juno) nachbildet. Er läuft als **Standalone-App** und als **AUv3-Instrument-Plugin** in GarageBand, AUM, Cubasis, Logic Pro für iPad, Drambo usw.

> Unabhängiges Projekt, nicht mit der Roland Corporation verbunden. „MKS-50“ und „Alpha Juno“ dienen nur als Beschreibung der nachgebildeten Architektur.

## Funktionen

| Bereich | Umsetzung |
|---|---|
| **DCO** | 4 Pulse-, 6 Sägezahn- und 6 Sub-Wellenformen (Alpha-Juno-Varianten wie gated/chopped Saw, PWM-Saw), Range 16'/8'/4'/2', Sub-Level, Noise. Alle Wellen phasenstarr über einen Teiler (wie die Hardware) und mit PolyBLEP bandbegrenzt |
| **PWM** | PW/PWM-Tiefe und eigene PWM-Rate (Rate 0 = manuelle Pulsbreite) |
| **HPF** | 4 Stufen: Bass-Boost, flach, 240 Hz, 720 Hz |
| **VCF** | Resonanter 24-dB-Tiefpass (IR3109-Stil, Zero-Delay-Feedback), selbstoszillierend, Env/LFO/Key-Follow/Aftertouch-Modulation |
| **VCA** | ENV- oder GATE-Modus, jeweils mit/ohne Velocity („Dynamics“) |
| **ENV** | Alpha-Juno-Hüllkurve mit 4 Zeiten und 3 Pegeln (T1/L1, T2/L2, T3/L3, T4) plus Key-Follow; Env-Modi normal/invertiert, mit/ohne Dynamics für DCO und VCF |
| **LFO** | Rate und Delay (Einblendung pro Tastenanschlag) |
| **Chorus** | Juno-artiger Stereo-BBD-Chorus mit Rate-Regler |
| **Patch** | Key-Modi **Poly / Chord / Mono**, 16 Chord-Memory-Speicher (per „LEARN“ von gehaltenen Tasten), Portamento, Bender-Range, Mod-Sensitivity, Key Shift, Volume |
| **Stimmen** | 6 Stimmen (wie das Original), Voice Stealing, Sustain-Pedal |
| **MIDI** | CoreMIDI (USB, Netzwerk, **Bluetooth LE MIDI**), virtueller Port „MKS50 Synth“ für andere Apps, Empfangskanal Omni/1–16, Pitch Bend, Mod Wheel (CC1), Aftertouch, Sustain (CC64), Portamento (CC5/CC65), Program Change |
| **SysEx** | Empfang von MKS-50/Alpha-Juno-**Tone-Dumps (APR)** und **Einzelparameter (IPR)**, z. B. vom PG-300 oder einem Editor; Import/Export von `.syx`-Dateien; Senden des aktuellen Sounds an ein echtes MKS-50 |
| **Presets** | 16 eigene Factory-Sounds (u. a. Hoover, Juno Brass, Strings, House Stab), User-Presets (AUv3-Preset-System, funktioniert auch im Host) |
| **UI** | SwiftUI-Panel im Look der schwarz-orangen Hardware, Drehregler (ziehen, Doppeltipp = Standardwert), Hüllkurvengrafik, Multitouch-Keyboard mit Velocity, Bend-/Mod-/Aftertouch-Streifen, VoiceOver-Unterstützung |

Die Parameteradressen 0–35 entsprechen exakt den Tone-Parameternummern des MKS-50. Damit sind die SysEx-Nachrichten direkt kompatibel, und Host-Automation verwendet dieselben Wertebereiche wie die Hardware (0–127 bzw. diskrete Schalter).

## Vorbilder aus der Plugin-Welt – und wie sie für iOS angepasst wurden

- **Apple-AUv3-Instrument-Vorlage**: Eine Audio-Unit-Klasse (`MKS50AudioUnit`) wird sowohl in der App (in-process über `AUAudioUnit.registerSubclass`) als auch in der Extension genutzt. Die App ist damit nur ein „Host“ ihres eigenen Plugins – genau wie Desktop-Plugins Standalone und VST/AU aus einem Kern bauen.
- **Juno-/Alpha-Juno-Emulationen (z. B. TAL-U-NO-LX, Dexed-artige Editoren mit SysEx-Unterstützung)**: Parameter in Hardware-Einheiten, SysEx-kompatible Tone-Daten, Preset-Import per `.syx`.
- **Echtzeit-Regeln aus JUCE/iPlug**: Im Render-Thread wird nichts allokiert und nie blockiert. MIDI vom UI-/CoreMIDI-Thread kommt über eine Queue, die der Audio-Thread nur mit `os_unfair_lock_trylock` liest. Parameter-Events des Hosts werden sample-genau verarbeitet.
- **iOS-spezifisch**: Multitouch-Keyboard statt Maus, Bluetooth-MIDI-Pairing mit Apples Standard-Dialog, Audio-Session mit 5-ms-Puffer und Hintergrund-Audio, Wiederanlauf nach Unterbrechungen und Routenwechseln, Dateien über die Dateien-App, Querformat-Layout für iPhone und iPad.

## Projektstruktur

```
MKS50.xcodeproj         Xcode-16-Projekt (synchronisierte Ordner)
Shared/                 wird in App UND Extension kompiliert
  DSP/                  DCO, LadderFilter, Envelope, Chorus, SynthEngine
  AU/                   MKS50AudioUnit (AUv3, Parameterbaum, Presets, State)
  Model/                Parameter (MKS-50-Nummerierung), ToneData + SysEx, Presets, Chords
  UI/                   SwiftUI-Panel, Regler, Keyboard, ViewModel
MKS50App/               Standalone-App: AVAudioEngine-Host, CoreMIDI, Einstellungen
MKS50AU/                AUv3-Extension: AudioUnitViewController (Factory + UI)
Config/                 Info.plists (Hintergrund-Audio, AudioComponents)
```

Signalfluss pro Stimme: `DCO → HPF → VCF (24 dB) → VCA`, danach Summe → DC-Blocker → Chorus (Stereo) → Soft-Limiter.

## Bauen & Installieren

Voraussetzungen: macOS mit **Xcode 16** oder neuer, iOS/iPadOS 16+.

1. `MKS50.xcodeproj` öffnen.
2. Für beide Targets (**MKS50** und **MKS50AU**) unter *Signing & Capabilities* das eigene Team auswählen. Falls nötig die Bundle-IDs `de.robtron.mks50` / `de.robtron.mks50.AUv3` anpassen. Die ID der Extension muss mit der ID der App beginnen.
3. Schema **MKS50** wählen, auf einem Gerät oder im Simulator starten.
4. Die AUv3-Version erscheint nach der ersten Installation automatisch in Hosts unter *Robtron → MKS50 Synth*.

Hinweis: Auch der Debug-Build ist mit `-O` optimiert, weil Swift-DSP ohne Optimierung auf dem Gerät Aussetzer verursachen kann.

## Bedienung

- **Regler**: hoch/runter oder links/rechts ziehen; Doppeltipp setzt den Standardwert.
- **Presets**: Tippen auf die grüne Anzeige öffnet die Preset-Liste; Pfeile blättern durch die Factory-Sounds.
- **Chord Memory**: Key-Mode auf CHORD stellen, Akkord auf der Tastatur halten, LEARN tippen. Die Akkorde werden mit dem Preset gespeichert.
- **Hardware-MKS-50**: In den Einstellungen den MIDI-Kanal wählen; der Papierflieger sendet den aktuellen Tone als APR-SysEx. Tone-Dumps vom Gerät werden live übernommen.

## Grenzen / Ideen für später

- Die Wellenformvarianten (Saw 2–5, Pulse 3, Sub 2–5) sind klanglich angenähert, nicht sample-genau.
- Bulk-Dumps (BLD, 64 Töne gepackt) werden noch nicht gelesen, nur APR-Einzel-Tones (auch mehrere in einer Datei).
- In der AUv3-Extension wird SysEx vom Host nicht ausgewertet (Parameter-Automation funktioniert vollständig).
- Mögliche Erweiterungen: MPE, Unison, Oversampling des Filters, Patch-Ebene (Patch-APR), Ableton-Link-gesynchter LFO.
