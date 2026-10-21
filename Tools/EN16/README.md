# Grid EN16 für die MKS-50-App

Zwei Grid-Editor-Profile für das Intech Studio **Grid EN16** (16 Endlos-Encoder mit Drucktaster). Damit spielst du den Synth live: Sound verändern, Arp und Sequencer, Recorder und Loop-Pads.

## Einrichten

1. Profile erzeugen und in den Grid Editor legen (sie erscheinen dort unter *My Configs*):
   ```
   python3 Tools/en16_profiles.py --install
   ```
   Ohne `--install` landen sie nur hier in `Tools/EN16`.
2. Im Grid Editor am EN16 **Seite 1** wählen, das Profil **MKS50 Page 1 Sound** daraufziehen und *Store* drücken.
3. **Seite 2** wählen, **MKS50 Page 2 Perform** daraufziehen, *Store*.
4. EN16 per USB an das iPhone (oder an den Mac mit Network MIDI) anschließen. In der App unter *Einstellungen* ist **Grid EN16 Controller (Ch 16)** standardmäßig an.

Die **Seitentaste** des EN16 schaltet zwischen Seite 1 und 2 um.

## Seite 1: Sound

Drehen verändert den Parameter. **Drücken** setzt ihn auf den Wert des geladenen Presets zurück. Die **LED leuchtet hell**, solange der Wert vom Preset abweicht.

| | 1 | 2 | 3 | 4 |
|---|---|---|---|---|
| **Filter** (orange) | Cutoff | Resonance | VCF Env | HPF |
| **Modulation** (grün) | LFO Rate | LFO → VCF | Vibrato (LFO → DCO) | PW/PWM |
| **Hüllkurve** (weiß) | Attack (T1) | Decay (T2) | Sustain (L3) | Release (T4) |
| **Effekte** (violett) | Delay Mix | Delay Feedback | Reverb Mix | Drive |

## Seite 2: Perform

Jede Zelle: **Drehen** / **Drücken**. Die LED leuchtet, wenn die Funktion an ist.

| | 1 | 2 | 3 | 4 |
|---|---|---|---|---|
| **Arp / Seq** (violett) | Arp Rate / **Arp an/aus** | Arp Mode / **Hold** | Seq Rate / **Seq an/aus** | Seq Gate / **neues Muster** |
| **Perform** (grün) | Seq G.Var / **Vary** | Transpose / **zurück auf 0** | Tempo / **Tap Tempo** | Stutter-Rate / **Stutter (halten)** |
| **Recorder** (orange) | Takte 1/2/4/8 / **REC** | Preset ◀ ▶ / **TAILS** | Lautstärke / **AUTO** | Loops gesamt / **alle stoppen** |
| **Loop-Pads** (blau) | Pad 1 Pegel / **Play/Stop** | Pad 2 … | Pad 3 … | Pad 4 … |

LED-Zustände: aus, **halb** (REC armiert, Pad wartet auf den Takt oder nimmt gerade auf, Pad belegt aber gestoppt: schwach), **voll** (an / spielt / nimmt auf).

## Technik

- MIDI-Kanal 16. Encoder senden **relativ** (Binary Offset: 64 ± Schritte), so springt nach einem Preset-Wechsel nichts. Listen (Arp Mode, Rate, Takte, Presets) gehen einen Schritt pro Rastung.
- Seite 1: Encoder CC 32–47, Taster CC 64–79. Seite 2: Encoder CC 48–63, Taster CC 80–95.
- Die App schickt die LED-Zustände auf den Taster-CCs zurück, nur an MIDI-Ziele mit „Grid“ oder „Intech“ im Namen. Beim Seitenwechsel meldet das EN16 CC 96, die App schickt dann alle LEDs neu.
- Diese CCs auf Kanal 16 gehen nicht an MIDI-Learn. Wer Kanal 16 anders braucht, schaltet *Grid EN16 Controller* in den Einstellungen aus.
- Belegung ändern: `soundPage` in `MKS50App/GridController.swift` und die Beschriftungen in `Tools/en16_profiles.py` gemeinsam anpassen, dann die Profile neu erzeugen.
