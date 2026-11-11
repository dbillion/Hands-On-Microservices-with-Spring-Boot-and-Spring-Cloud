#!/usr/bin/env python3
"""Ch14 correlation check: does the trace context cross each hop?

A distributed trace is correlated only when a CLIENT span and the target
service's SERVER span share one span id. Count, across every multi-service trace
Zipkin holds, how many client spans found a server span with the same id.
"""
import json, subprocess, sys, collections

Q = "http://localhost:9411/api/v2/traces?serviceName=product-composite&limit=200"
out = subprocess.run(["curl", "-s", "-m", "30", Q], capture_output=True, text=True).stdout
traces = json.loads(out) if out.strip() else []

lines = []
multi = [t for t in traces if len({s.get("localEndpoint", {}).get("serviceName")
                                   for s in t}) > 1]
lines.append(f"traces fetched (serviceName=product-composite): {len(traces)}")
lines.append(f"of those, spanning more than one service:      {len(multi)}")
lines.append("")

# per-service span totals across everything fetched
per_service = collections.Counter()
for t in traces:
    for s in t:
        per_service[s.get("localEndpoint", {}).get("serviceName")] += 1
lines.append("spans by service:")
for name, n in per_service.most_common():
    lines.append(f"    {name}: {n}")
lines.append("")

# the correlation check
lines.append("client -> server span-id sharing, per multi-service trace:")
ok = bad = 0
pairs = []
for t in multi:
    by_id = {s["id"]: s for s in t}
    for s in t:
        if s.get("kind") == "CLIENT":
            tgt = by_id.get(s["id"])
            caller = s.get("localEndpoint", {}).get("serviceName")
            if tgt and tgt.get("kind") == "SERVER":
                callee = tgt.get("localEndpoint", {}).get("serviceName")
                if caller != callee:
                    ok += 1
                    pairs.append((caller, s["id"][:8], callee))
            else:
                bad += 1
for caller, sid, callee in pairs[:12]:
    lines.append(f"    OK   {caller} CLIENT {sid} -> {callee} SERVER {sid}")
lines.append(f"    total: {ok} client spans whose server-side counterpart shares the same span id")
lines.append(f"           {bad} client spans with no server span of the same id")
lines.append("")

# largest trace, laid out
biggest = max(multi, key=len) if multi else []
lines.append("largest multi-service trace:")
lines.append(f"    traceId: {biggest[0]['traceId'] if biggest else '-'}")
lines.append(f"    spans:   {len(biggest)}")
lines.append(f"    services:{', ' + ', '.join(sorted({s.get('localEndpoint', {}).get('serviceName') for s in biggest})) if biggest else ''}")
for s in sorted(biggest, key=lambda x: x.get("timestamp", 0)):
    svc = s.get("localEndpoint", {}).get("serviceName")
    lines.append(f"    {svc:<20} {s.get('kind', ''):<8} {str(s.get('name'))[:44]:<44} "
                 f"id={s['id'][:8]} parent={(s.get('parentId') or '-')[:8]}")

open("/tmp/ch14-corr.txt", "w").write("\n".join(lines) + "\n")
print("\n".join(lines))
