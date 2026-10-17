#!/usr/bin/env python3
"""Checks the Revit gron snippets (photos/gron_rvt.py) on a synthetic rvt2text outline; no Revit file needed."""
import os, sys
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "photos"))
import gron_rvt as G

T = """# Revit file: demo.rvt
Revit version: 2022
Editors: ann, bob, cy
Families (3): Door; Window; Fire Door
Levels:
  Level 1  elevation 0.000 ft (0.000 m)  [UniqueId u1 IfcGUID g1]
  Level 2  elevation 9.843 ft (3.000 m)  [UniqueId u2 IfcGUID g2]
Rooms, spaces and areas:
  Room 1 Kitchen  (level Level 1)  [UniqueId r1 IfcGUID q1]
"""
fails = 0
def check(name, ok):
    global fails
    print(("ok   " if ok else "FAIL ") + name); fails += 0 if ok else 1

leaves = dict(G.outline_leaves(T))
check("top-level fact", leaves["json.revit_version"] == "2022")
check("comma list becomes an array", leaves["json.editors[2]"] == "cy")
check("semicolon list becomes an array", leaves["json.families[2]"] == "Fire Door")
check("section element fields", leaves["json.levels[1].elevation"] == "9.843 ft (3.000 m)" and leaves["json.levels[1].uniqueid"] == "u2")
check("room level split out", leaves["json.rooms_spaces_and_areas[0].level"] == "Level 1" and leaves["json.rooms_spaces_and_areas[0].name"] == "Room 1 Kitchen")
s = G.gron_snippets(T, "kitchen")
check("one snippet per matching element, gron syntax", len(s) == 1 and s[0]["text"].startswith('json.rooms_spaces_and_areas[0].name = "Room 1 Kitchen";'))
check("ranges are byte offsets of the match", s[0]["text"].encode()[s[0]["ranges"][0][0]:s[0]["ranges"][0][1]].lower() == b"kitchen")
check("flat lists show only the matching items", [x["text"] for x in G.gron_snippets(T, "door")] == ['json.families[0] = "Door";\njson.families[2] = "Fire Door";'])
check("-excluded and OR are not search words", G.query_words('kitchen OR -door "fire door" a*') == ["kitchen", "fire door", "a"] or G.query_words('kitchen OR -door "fire door" a*') == ["kitchen", "fire door"])
check("no match, no snippets", G.gron_snippets(T, "zebra") == [] and G.gron_snippets("", "x") == [])
print("\nALL OK" if not fails else f"\n{fails} FAILED"); sys.exit(1 if fails else 0)
