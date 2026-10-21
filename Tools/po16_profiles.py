#!/usr/bin/env python3
"""Grid Editor profiles for the Intech Studio Grid PO16 (MKS-50 app).

Writes one profile per PO16 page into Tools/PO16 (and, with --install, into
~/Documents/grid-userdata/configs, where Grid Editor lists them under
"My Configs"). Load "MKS50 PO16 Page 1 Sound" onto page 1 and
"MKS50 PO16 Page 2 Perform" onto page 2; the side button switches between them.

Protocol (MIDI channel 16, absolute 0...127, see GridController.swift):
  page 1: pot p -> CC 32+p      page 2: pot p -> CC 48+p
  CC 96 <- page loaded (the app then lets every pot pick up anew)

Run: python3 Tools/po16_profiles.py [--install]
"""
import json, os, sys, uuid
from datetime import datetime, timezone

APP = "MKS50"

# Colours of the app's theme (OP-1 encoder colours).
BLUE = (51, 120, 255)
GREEN = (28, 204, 120)
WHITE = (232, 232, 227)
ORANGE = (255, 94, 33)
VIOLET = (168, 120, 255)

# (name, colour) per pot, left to right, top to bottom.
SOUND = [
    ("CUTOFF", ORANGE), ("RESO", ORANGE), ("VCF ENV", ORANGE), ("HPF", ORANGE),
    ("LFO RATE", GREEN), ("LFO>VCF", GREEN), ("VIBRATO", GREEN), ("PW/PWM", GREEN),
    ("ATTACK T1", WHITE), ("DECAY T2", WHITE), ("SUSTAIN L3", WHITE), ("RELEASE T4", WHITE),
    ("DLY MIX", VIOLET), ("DLY FB", VIOLET), ("DLY TIME", VIOLET), ("REV MIX", VIOLET),
]
PERFORM = [
    ("ARP off|on", VIOLET), ("ARP RATE", VIOLET), ("SEQ off|on", VIOLET), ("SEQ RATE", VIOLET),
    ("SEQ GATE", GREEN), ("SEQ G.VAR", GREEN), ("TRANSPOSE", GREEN), ("STUTTER", GREEN),
    ("TEMPO", ORANGE), ("HOLD off|on", ORANGE), ("REC >", ORANGE), ("LOOPS", ORANGE),
    ("PAD 1", BLUE), ("PAD 2", BLUE), ("PAD 3", BLUE), ("PAD 4", BLUE),
]

VERSION = {"major": "1", "minor": "7", "patch": "5"}

# This app's PO16 pages and MIDI channel (the other app uses the other two
# pages and its own channel, so one PO16 plays both).
CHANNEL = 15                  # 1...16 (Grid counts 0...15)
SOUND_PAGE, PERFORM_PAGE = 3, 4

# Mapping version: part of every profile name, so versions are told apart
# in Grid Editor. Raise it whenever the layout changes (and note why).
#   v1  first PO16 layout (effects row with Drive)
#   v2  effects row: Delay Mix, Delay Feedback, Delay Time, Reverb Mix
#   v3  both apps on one PO16: JP6 pages 1-2 (channel 16), MKS-50 pages 3-4
#       (channel 15); the side button steps through all four pages
MAPPING_VERSION = "v3"
MAPPING_NOTE = "v3: JP6 pages 1-2 (ch 16), MKS-50 pages 3-4 (ch 15)"


def pot(index, name, colour, cc):
    r, g, b = colour
    return {
        "controlElementNumber": index,
        "events": [
            {"event": 0, "config": f'--[[@sn]] self:gen("{name}")--[[@cb]] --[[Potmeter Init]]'},
            {"event": 1, "config": "--[[@spc]] self:pmo(7) self:pmi(0) self:pma(127)"
                                   f"--[[@sglc]] self:glc(-1,{{{{{r},{g},{b},1}}}}) self:glp(-1,-1)"
                                   f"--[[@gms]] self:gms({CHANNEL - 1},176,{cc},-1)"},
            {"event": 6, "config": '--[[@cb]] print("tick")'},
        ],
    }


def system():
    return {
        "controlElementNumber": 255,
        "events": [
            # Tell the app which page is active (CC 96), so pots pick up anew.
            {"event": 0, "config": f"--[[@cb]] gms({CHANNEL - 1},176,96,gpc())"},
            # Side button: next page, 1 -> 2 -> 3 -> 4 -> 1 (JP6 and MKS-50).
            {"event": 4, "config": "--[[@cb]] gpl((gpc()+1)%4)"},
            {"event": 6, "config": '--[[@cb]] print("tick")'},
        ],
    }


def profile(name, description, layout, base_cc):
    now = datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")
    configs = [pot(i, n, c, base_cc + i) for i, (n, c) in enumerate(layout)]
    configs.append(system())
    return {
        "id": str(uuid.uuid5(uuid.NAMESPACE_URL, f"robtron/{APP}/{name}")),
        "name": name,
        "description": description,
        "type": "PO16",
        "version": VERSION,
        "configType": "profile",
        "files": [],
        "createdAt": now,
        "modifiedAt": now,
        "virtualPath": "",
        "configs": configs,
    }


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    profiles = [
        (f"{APP} PO16 {MAPPING_VERSION} Page {SOUND_PAGE} Sound",
         f"{APP} app, PO16 page {SOUND_PAGE}, MIDI ch {CHANNEL}: filter, modulation, envelope, effects. "
         "Pots pick up at the current value. Side button: next page. "
         f"Mapping {MAPPING_NOTE}.",
         SOUND, 32),
        (f"{APP} PO16 {MAPPING_VERSION} Page {PERFORM_PAGE} Perform",
         f"{APP} app, PO16 page {PERFORM_PAGE}, MIDI ch {CHANNEL}: arp / sequencer, transpose, stutter, tempo, "
         "hold, REC, loop pads. Side button: next page. "
         f"Mapping {MAPPING_NOTE}.",
         PERFORM, 48),
    ]
    targets = [os.path.join(here, "PO16")]
    if "--install" in sys.argv:
        targets.append(os.path.expanduser("~/Documents/grid-userdata/configs"))
    for name, desc, layout, base in profiles:
        data = json.dumps(profile(name, desc, layout, base), indent=2)
        for folder in targets:
            os.makedirs(folder, exist_ok=True)
            path = os.path.join(folder, name.replace(" ", "-") + ".json")
            with open(path, "w") as f:
                f.write(data + "\n")
            print("wrote", path)


if __name__ == "__main__":
    main()
