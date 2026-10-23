# Grid PO16 für die MKS-50-App

Zwei Grid-Editor-Profile für das Intech Studio **Grid PO16** (16 Drehregler). Damit spielst du den Synth live: Sound verändern, Arp und Sequencer, Recorder und Loop-Pads.

## Einrichten

1. Profile erzeugen und in den Grid Editor legen (sie erscheinen dort unter *My Configs*):
   ```
   python3 Tools/po16_profiles.py --install
   ```
   Ohne `--install` landen sie nur hier in `Tools/PO16`.
2. Im Grid Editor am PO16 **Seite 3** wählen, **MKS50 PO16 v3 Page 3 Sound** daraufziehen und *Store* drücken.
3. **Seite 4** wählen, **MKS50 PO16 v3 Page 4 Perform** daraufziehen, *Store*.
   Die andere App liegt auf den Seiten 1 und 2 (**JP6 PO16 v3 …**, Kanal 16). So steuert ein PO16 beide Apps, auch wenn beide gleichzeitig laufen.
4. PO16 per USB an das iPhone (oder an den Mac mit Network MIDI) anschließen. In der App unter *Einstellungen* ist **Grid PO16 Controller (Ch 15)** standardmäßig an.

Die **Seitentaste** des PO16 schaltet weiter: 1 → 2 → 3 → 4 → 1. Seiten 1–2 steuern die JP6-App (Kanal 16), Seiten 3–4 die MKS-50-App (Kanal 15).

**Sanfte Übernahme:** Nach einem Preset-Wechsel, einem Seitenwechsel oder einer Änderung am Bildschirm springt nichts: Steht der Regler woanders als der Wert, bewegt sich der Wert trotzdem sofort mit, nur entsprechend langsamer oder schneller, sodass Regler und Wert am Ende des Drehwegs zusammenkommen. Ab dann folgt der Wert dem Regler direkt.

## Seite 3: Sound

| | 1 | 2 | 3 | 4 |
|---|---|---|---|---|
| **Filter** (orange) | Cutoff | Resonance | VCF Env | HPF |
| **Modulation** (grün) | LFO Rate | LFO → VCF | Vibrato (LFO → DCO) | PW/PWM |
| **Hüllkurve** (weiß) | Attack (T1) | Decay (T2) | Sustain (L3) | Release (T4) |
| **Effekte** (violett) | Delay Mix | Delay Feedback | Delay Time (Notenwert, ohne Sync: Zeit) | Reverb Mix |

## Seite 4: Perform

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

Die Version steht im Profilnamen (z. B. *MKS50 PO16 v3 Page 3 Sound*) und auf dem Ausdruck.

- **v3** (aktuell): beide Apps auf einem PO16. JP6 auf Seiten 1–2 (Kanal 16), MKS-50 auf Seiten 3–4 (Kanal 15); die Seitentaste geht durch alle vier Seiten.
- **v2**: Effekt-Reihe Delay Mix, Delay Feedback, Delay Time, Reverb Mix.
- **v1**: erste PO16-Fassung, Effekt-Reihe mit Drive statt Delay Time.

Bei jeder Änderung der Belegung `MAPPING_VERSION` in `Tools/po16_profiles.py` erhöhen.

## Technik

- MIDI-Kanal 15, absolute Werte. Seite 3: CC 32–47, Seite 4: CC 48–63. Beim Laden einer Seite meldet das PO16 CC 96, die App lässt dann alle Regler neu aufnehmen. Die App reagiert nur auf Kanal 15, die andere App nur auf Kanal 16.
- Diese CCs auf Kanal 15 gehen nicht an MIDI-Learn. Wer Kanal 15 anders braucht, schaltet *Grid PO16 Controller* in den Einstellungen aus.
- Belegung ändern: `soundPage` in `MKS50App/GridController.swift` und die Namen in `Tools/po16_profiles.py` gemeinsam anpassen, dann die Profile neu erzeugen.
