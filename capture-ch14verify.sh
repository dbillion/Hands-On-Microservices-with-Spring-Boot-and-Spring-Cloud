#!/bin/bash
# Ch14 verification: the book's own suite does NOT check tracing, so capture the
# tracing evidence separately. Two things matter:
#   1. which services actually report spans into Zipkin
#   2. that ONE request produces ONE trace spanning all of them, with the client
#      and server spans sharing one span id (that sharing IS B3 propagation)
# Zipkin's in-memory store is dominated by eureka's heartbeat traces, so filter
# by serviceName rather than pulling the newest N traces.
OUT=/tmp/ch14-tracing.txt
TOK=$(curl -sk -s https://writer:secret@localhost:8443/oauth/token -d grant_type=password -d username=magnus -d password=password | jq -r .access_token)

{
echo "===== ONE TRACED REQUEST ====="
echo "  GET https://localhost:8443/product-composite/2 (through the gateway)"
curl -sk -o /dev/null -w "  HTTP=%{http_code}\n" -H "Authorization: Bearer $TOK" 'https://localhost:8443/product-composite/2'
sleep 20

echo
echo "===== SERVICES THAT REPORT SPANS (queried per service, not by recency) ====="
for s in gateway product-composite product review recommendation auth-server eureka-server; do
  SPANS=$(curl -s -m 20 "http://localhost:9411/api/v2/traces?serviceName=$s&limit=200" | jq -r "[.[][] | select(.localEndpoint.serviceName==\"$s\")] | length" 2>/dev/null)
  TRACES=$(curl -s -m 20 "http://localhost:9411/api/v2/traces?serviceName=$s&limit=200" | jq -r 'length' 2>/dev/null)
  echo "    $s: ${SPANS} span(s) across ${TRACES} trace(s)"
done

echo
echo "===== TRACES SPANNING MORE THAN ONE SERVICE ====="
curl -s -m 25 'http://localhost:9411/api/v2/traces?serviceName=product-composite&limit=200' | jq -r '
  [.[] | select(([.[]?.localEndpoint.serviceName] | unique | length) > 1)] as $m
  | "    multi-service traces: \($m | length)"' 2>&1

echo
echo "===== THE LARGEST SUCH TRACE, SPAN BY SPAN (id / parent) ====="
curl -s -m 25 'http://localhost:9411/api/v2/traces?serviceName=product-composite&limit=200' | jq -r '
  [.[] | select(([.[]?.localEndpoint.serviceName] | unique | length) > 1)] | max_by(length) as $t
  | "    traceId:  \($t[0].traceId)",
    "    services: \([$t[]?.localEndpoint.serviceName] | unique | join(", "))",
    "    spans:    \($t | length)",
    ($t | sort_by(.timestamp) | .[]
      | "    \(.localEndpoint.serviceName)  kind=\(.kind)  name=\(.name)  id=\(.id[0:8])  parent=\((.parentId // "-")[0:8])")'

echo
echo "===== CORRELATION: does each CLIENT span share an id with its SERVER span? ====="
echo "  (a different id would mean the trace context was lost between hops)"
curl -s -m 25 'http://localhost:9411/api/v2/traces?serviceName=product-composite&limit=200' | jq -r '
  [.[] | select(([.[]?.localEndpoint.serviceName] | unique | length) > 1)] | max_by(length) as $t
  | [$t[] | select(.kind == "CLIENT")]
  | .[]
  | "    composite CLIENT \(.id[0:8]) -> \([$t[] | select(.id == .id)] | .[0].localEndpoint.serviceName) SERVER \(.id[0:8])"'
} > $OUT 2>&1
cat $OUT
