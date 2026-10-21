# Grid PO16 für die MKS-50-App

Zwei Grid-Editor-Profile für das Intech Studio **Grid PO16** (16 Drehregler). Damit spielst du den Synth live: Sound verändern, Arp und Sequencer, Recorder und Loop-Pads.

## Einrichten

1. Profile erzeugen und in den Grid Editor legen (sie erscheinen dort unter *My Configs*):
   ```
   python3 Tools/po16_profiles.py --install
   ```
   Ohne `--install` landen sie nur hier in `Tools/PO16`.
2. Im Grid Editor am PO16 **Seite 1** wählen, **MKS50 PO16 v2 Page 1 Sound** daraufziehen und *Store* drücken.
3. **Seite 2** wählen, **MKS50 PO16 v2 Page 2 Perform** daraufziehen, *Store*.
4. PO16 per USB an das iPhone (oder an den Mac mit Network MIDI) anschließen. In der App unter *Einstellungen* ist **Grid PO16 Controller (Ch 16)** standardmäßig an.

Die **Seitentaste** des PO16 schaltet zwischen Seite 1 und 2.

**Pickup:** Nach einem Preset-Wechsel, einem Seitenwechsel oder einer Änderung am Bildschirm greift ein Regler erst, wenn du ihn bis zum aktuellen Wert drehst. So springt nichts.

## Seite 1: Sound

| | 1 | 2 | 3 | 4 |
|---|---|---|---|---|
| **Filter** (orange) | Cutoff | Resonance | VCF Env | HPF |
| **Modulation** (grün) | LFO Rate | LFO → VCF | Vibrato (LFO → DCO) | PW/PWM |
| **Hüllkurve** (weiß) | Attack (T1) | Decay (T2) | Sustain (L3) | Release (T4) |
| **Effekte** (violett) | Delay Mix | Delay Feedback | Delay Time (Notenwert, ohne Sync: Zeit) | Reverb Mix |

## Seite 2: Perform

| | 1 | 2 | 3 | 4 |
|---|---|---|---|---|
| **Arp / Seq** (violett) | **ARP** links aus, rechts an | Arp Rate | **SEQ** links aus, rechts an | Seq Rate |
| **Perform** (grün) | Seq Gate | Seq G.Var | Transpose (−12 … +12) | **Stutter**: linkes Viertel aus, dann 1/4 → 1/32 |
| **Recorder** (orange) | Tempo 60–187 BPM | **HOLD** links aus, rechts an | **REC**: über die Mitte drehen startet eine Aufnahme | Pegel aller Loops |
| **Loop-Pads** (blau) | Pad 1 | Pad 2 | Pad 3 | Pad 4 |

- **Schalter** (ARP, SEQ, HOLD) schalten, wenn der Regler die Mitte überquert.
- **REC** startet die Aufnahme beim Drehen über die Mitte. Für die nächste Aufnahme erst wieder nach links drehen. Takte, START und TAILS stellst du in der App ein.
- **Pad-Regler** sind Pegel und Start/Stop zugleich: ganz links stoppt das Pad, von ganz links aufgedreht startet es auf dem nächsten Takt.

## Versionen

Die Version steht im Profilnamen (z. B. *MKS50 PO16 v2 Page 1 Sound*) und auf dem Ausdruck.

- **v2** (aktuell): Effekt-Reihe Delay Mix, Delay Feedback, Delay Time, Reverb Mix.
- **v1**: erste PO16-Fassung, Effekt-Reihe mit Drive statt Delay Time.

Bei jeder Änderung der Belegung `MAPPING_VERSION` in `Tools/po16_profiles.py` erhöhen.

## Technik

- MIDI-Kanal 16, absolute Werte. Seite 1: CC 32–47, Seite 2: CC 48–63. Beim Laden einer Seite meldet das PO16 CC 96, die App lässt dann alle Regler neu aufnehmen.
- Diese CCs auf Kanal 16 gehen nicht an MIDI-Learn. Wer Kanal 16 anders braucht, schaltet *Grid PO16 Controller* in den Einstellungen aus.
- Belegung ändern: `soundPage` in `MKS50App/GridController.swift` und die Namen in `Tools/po16_profiles.py` gemeinsam anpassen, dann die Profile neu erzeugen.
