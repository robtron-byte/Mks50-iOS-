#!/usr/bin/env python3
"""Grid Editor profiles for the Intech Studio Grid EN16 (MKS-50 app).

Writes one profile per EN16 page into Tools/EN16 (and, with --install, into
~/Documents/grid-userdata/configs, where Grid Editor lists them under
"My Configs"). Load "… Page 1 Sound" onto page 1 and "… Page 2 Perform"
onto page 2 of the EN16; the side button switches between the two.

Protocol (MIDI channel 16, see GridController.swift in the app):
  page 1: encoder e -> CC 32+e (relative, 64 +/- steps), push -> CC 64+e
  page 2: encoder e -> CC 48+e,                           push -> CC 80+e
  CC 96 <- page loaded (the app then resends all LED states)
  LED feedback from the app arrives on the push CC numbers (0 / 64 / 127).

Run: python3 Tools/en16_profiles.py [--install]
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

# (label, colour) per element, left to right, top to bottom.
SOUND = [
    ("CUTOFF", ORANGE), ("RESO", ORANGE), ("VCF ENV", ORANGE), ("HPF", ORANGE),
    ("LFO RATE", GREEN), ("LFO>VCF", GREEN), ("VIBRATO", GREEN), ("PW/PWM", GREEN),
    ("ATTACK T1", WHITE), ("DECAY T2", WHITE), ("SUSTAIN L3", WHITE), ("RELEASE T4", WHITE),
    ("DLY MIX", VIOLET), ("DLY FB", VIOLET), ("REV MIX", VIOLET), ("DRIVE", VIOLET),
]
PERFORM = [
    ("ARP RATE / ARP", VIOLET), ("ARP MODE / HOLD", VIOLET), ("SEQ RATE / SEQ", VIOLET), ("SEQ GATE / NEW", VIOLET),
    ("SEQ G.VAR / VARY", GREEN), ("TRANSPOSE / RESET", GREEN), ("TEMPO / TAP", GREEN), ("STUTTER RATE / HOLD", GREEN),
    ("REC BARS / REC", ORANGE), ("PRESET / TAILS", ORANGE), ("VOLUME / AUTO", ORANGE), ("LOOPS LEVEL / STOP", ORANGE),
    ("PAD 1 LEVEL / PLAY", BLUE), ("PAD 2 LEVEL / PLAY", BLUE),
    ("PAD 3 LEVEL / PLAY", BLUE), ("PAD 4 LEVEL / PLAY", BLUE),
]

VERSION = {"major": "1", "minor": "6", "patch": "2"}


def element(index, label, colour, encoder_cc, push_cc):
    r, g, b = colour
    init = (f"--[[@cb]] --[[{label}]] self:emo(1) self:ev0(50) self:ese(100) self:emi(0) self:ema(127) "
            f"self:eva(64) self:glc(1,{{{{{r},{g},{b},1}}}}) self:glc(2,{{{{{r},{g},{b},1}}}}) "
            f"self:glp(2,40) self:glp(1,0)")
    return {
        "controlElementNumber": index,
        "events": [
            {"event": 0, "config": init},
            # Relative (binary offset): 64 +/- steps, then back to the centre.
            {"event": 2, "config": f"--[[@cb]] self:gms(15,176,{encoder_cc},self:eva()) self:eva(64)"},
            {"event": 3, "config": f"--[[@cb]] self:gms(15,176,{push_cc},self:bst())"},
            {"event": 6, "config": "--[[@cb]] "},
        ],
    }


def system(feedback_base):
    # LED feedback from the app (channel 16, push CC numbers of this page),
    # and "page loaded" (CC 96) so the app resends the LED states.
    init = ("--[[@cb]] self.midirx_cb=function(self,h,d) "
            "if (d[1]==15 or d[1]==16) and (d[2]==176 or d[2]==191) then "
            f"local i=d[3]-{feedback_base} if i>=0 and i<16 then glp(i,1,d[4]*2) end end end "
            "gms(15,176,96,gpc())")
    return {
        "controlElementNumber": 255,
        "events": [
            {"event": 0, "config": init},
            # Side button: page 1 <-> page 2.
            {"event": 4, "config": "--[[@cb]] gpl((gpc()+1)%2)"},
            {"event": 5, "config": "--[[@cb]] "},
            {"event": 6, "config": "--[[@cb]] "},
        ],
    }


def profile(name, description, layout, encoder_base, push_base):
    now = datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")
    configs = [element(i, label, colour, encoder_base + i, push_base + i)
               for i, (label, colour) in enumerate(layout)]
    configs.append(system(push_base))
    return {
        "id": str(uuid.uuid5(uuid.NAMESPACE_URL, f"robtron/{APP}/{name}")),
        "name": name,
        "description": description,
        "type": "EN16",
        "version": VERSION,
        "configType": "profile",
        "createdAt": now,
        "modifiedAt": now,
        "configs": configs,
    }


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    out = os.path.join(here, "EN16")
    os.makedirs(out, exist_ok=True)
    profiles = [
        (f"{APP} Page 1 Sound",
         f"{APP} app, EN16 page 1: filter, modulation, envelope, effects. "
         "Push: back to the preset value (LED lit = changed). Side button: page 2.",
         SOUND, 32, 64),
        (f"{APP} Page 2 Perform",
         f"{APP} app, EN16 page 2: arp / sequencer, transpose, tempo, stutter, "
         "recorder, presets, loop pads. Side button: page 1.",
         PERFORM, 48, 80),
    ]
    targets = [out]
    if "--install" in sys.argv:
        targets.append(os.path.expanduser("~/Documents/grid-userdata/configs"))
    for name, desc, layout, enc, push in profiles:
        data = json.dumps(profile(name, desc, layout, enc, push), indent=2)
        for folder in targets:
            os.makedirs(folder, exist_ok=True)
            path = os.path.join(folder, name.replace(" ", "-") + ".json")
            with open(path, "w") as f:
                f.write(data + "\n")
            print("wrote", path)


if __name__ == "__main__":
    main()
