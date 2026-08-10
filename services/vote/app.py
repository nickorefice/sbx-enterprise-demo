#!/usr/bin/env python3
"""Voting service — accepts POST /vote?choice=<a|b> and tallies in-memory."""

import os
import datetime
from flask import Flask, request, jsonify

app = Flask(__name__)
votes: dict[str, int] = {"a": 0, "b": 0}


@app.get("/healthz")
def healthz():
    return {"status": "ok", "service": "vote"}


@app.post("/vote")
def vote():
    choice = request.args.get("choice", "").lower()
    if choice not in votes.keys():
        return jsonify({"error": "choice must be 'a' or 'b'"}), 400
    votes[choice] += 1
    return jsonify({"choice": choice, "totals": votes})


@app.get("/results")
def results():
    return jsonify(votes)


@app.get("/stats")
def stats():
    total = sum(votes.values())
    percentages = {k: round(v / total * 100, 1) if total else 0.0 for k, v in votes.items()}
    return jsonify({
        "percentages": percentages,
        "totals": votes,
        "timestamp": datetime.datetime.utcnow().isoformat() + "Z",
    })


if __name__ == "__main__":
    port = int(os.getenv("PORT", "5000"))
    app.run(host="0.0.0.0", port=port)
