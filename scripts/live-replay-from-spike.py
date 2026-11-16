#!/usr/bin/env python3
"""Rebuilds Gemini Live replay fixtures from the One loop spike's event logs.

The spike (docs/wukongmind/one-loop-spike) logged each real session as events
(user, call, response, turnComplete with the reply's transcript, usage,
audio-start), not wire frames. This turns the first correct repetition of each
distinct case into a LiveRecording (WukongMind/Voice/LiveReplay.swift):
server frames synthesized from the events, cut into steps at the client's
turns and tool responses. The model's calls, arguments, replies and token
counts are the real ones; call ids, frame boundaries and audio are not
(each audio-start becomes one short stub chunk), so `reconstructed` is true.

Usage: scripts/live-replay-from-spike.py   (writes WukongMindTests/Fixtures/LiveReplay/)
"""
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RESULTS = os.path.join(ROOT, "docs/wukongmind/one-loop-spike/results")
OUT = os.path.join(ROOT, "WukongMindTests/Fixtures/LiveReplay")
SOURCES = ["anywhere-utterances", "anywhere-links", "anywhere-forum-q3"]
AUDIO_STUB = "A" * 640  # 480 zero bytes, base64 (LiveRecording.audioStub)
AUDIO_TOKENS_PER_SECOND = 25  # Gemini bills output audio at 25 tokens/s


def frame(obj):
    return json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def convert(row, source, model):
    steps, notes, utterances, calls = [], [], [], []
    open_calls = []  # (id, name) not answered yet
    call_count = 0
    audio_tokens = 0
    turn_has_audio = False

    def add(f):
        if not steps:
            raise ValueError("server frame before setup")
        steps[-1]["frames"].append(frame(f))

    for event in row["events"]:
        kind, text = event["kind"], event["text"]
        if kind == "setup-sent":
            steps.append({"on": "setup", "frames": []})
        elif kind == "setupComplete":
            add({"setupComplete": {}})
        elif kind == "note":
            notes.append(text)
        elif kind == "user":
            utterances.append(text)
            steps.append({"on": "turn", "frames": []})
        elif kind == "call":
            name, _, args = text.partition(" ")
            call_count += 1
            call_id = f"call-{call_count}"
            open_calls.append((call_id, name))
            calls.append(name)
            add({"toolCall": {"functionCalls": [{"id": call_id, "name": name, "args": json.loads(args) if args.strip() else {}}]}})
        elif kind == "response":
            name = text.split(" ")[0]
            match = next((c for c in open_calls if c[1] == name), None)
            if match is None:
                raise ValueError(f"response without a call: {text}")
            open_calls.remove(match)
            steps.append({"on": f"toolResponse:{match[0]}", "frames": []})
        elif kind == "audio-start":
            turn_has_audio = True
            add({"serverContent": {"modelTurn": {"parts": [{"inlineData": {"mimeType": "audio/pcm;rate=24000", "data": AUDIO_STUB}}]}}})
        elif kind == "interrupted":
            add({"serverContent": {"interrupted": True}})
        elif kind == "turnComplete":
            if text:
                add({"serverContent": {"outputTranscription": {"text": text}}})
            add({"serverContent": {"generationComplete": True, "turnComplete": True}})
        elif kind == "usage":
            parts = text.split()
            prompt, response = int(parts[1]), int(parts[3])
            if turn_has_audio:
                audio_tokens += response
            turn_has_audio = False
            add({"usageMetadata": {"promptTokenCount": prompt, "responseTokenCount": response, "totalTokenCount": prompt + response}})
    # The spike stopped some rows while the model still spoke: close that turn.
    truncated = turn_has_audio
    if truncated:
        add({"serverContent": {"generationComplete": True, "turnComplete": True}})
    name = f"{row.get('page') or 'page'}: {row['utterance']}"
    return {
        "source": f"reconstructed from docs/wukongmind/one-loop-spike/results/{source}.json (rep {row.get('rep')}, {model}); "
                  "audioSeconds estimated from response tokens"
                  + ("; the log ended mid-reply, so a final turnComplete was added" if truncated else ""),
        "reconstructed": True,
        "model": model,
        "name": name,
        "page": row.get("page"),
        "notes": notes,
        "utterances": utterances,
        "calls": calls,
        "steps": steps,
        "audioSeconds": round(audio_tokens / AUDIO_TOKENS_PER_SECOND, 2),
    }


def main():
    os.makedirs(OUT, exist_ok=True)
    for source in SOURCES:
        with open(os.path.join(RESULTS, f"{source}.json")) as f:
            data = json.load(f)
        recordings, seen, skipped = [], set(), []
        cases = []
        for row in data["rows"]:
            key = (row["utterance"], row.get("page"))
            if key not in cases:
                cases.append(key)
        for key in cases:
            row = next((r for r in data["rows"] if (r["utterance"], r.get("page")) == key and r.get("correct")), None)
            if row is None:
                skipped.append(f"{key[1] or 'page'}: {key[0]}")
                continue
            recordings.append(convert(row, source, data.get("model", "")))
        path = os.path.join(OUT, f"{source}.json")
        with open(path, "w") as f:
            json.dump({"recordings": recordings, "skipped": skipped}, f, indent=1, ensure_ascii=False, sort_keys=True)
            f.write("\n")
        print(f"{path}: {len(recordings)} recordings, skipped (no correct rep): {skipped}", file=sys.stderr)


if __name__ == "__main__":
    main()
