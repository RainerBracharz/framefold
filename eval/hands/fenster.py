"""Schreibt die ruhigen Fenster eines Videos mit ihren Kandidaten (nach Schärfe
sortiert, wie KeyframeSelector.rankedCandidates) als JSON. Für pipeline_sim.py.
Aufruf (aus eval/): .venv/bin/python hands/fenster.py video.mp4 > hands/fenster.json"""
import json, sys
sys.path.insert(0, ".")
from selector import Settings, select

sel = select(sys.argv[1], Settings())
json.dump(sel["ranked_windows"], sys.stdout)
