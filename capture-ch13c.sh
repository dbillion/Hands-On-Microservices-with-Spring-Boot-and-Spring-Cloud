#!/bin/bash
# Ch13 breaker verification — corrected IDs (2 and 13, the book's
# PROD_ID_REVS_RECS and PROD_ID_NOT_FOUND), correct protocol split, and the
# breaker reset first so 2a starts from a known state.
W=/workspaces/Hands-On-Microservices-with-Spring-Boot-and-Spring-Cloud
OUT=/tmp/ch13-breaker2.txt
cd $W/Chapter13 || exit 1
source /usr/local/sdkman/bin/sdkman-init.sh >/dev/null 2>&1
export ENCRYPT_KEY=my-very-secure-encrypt-key
export CONFIG_SERVER_USR=dev-usr CONFIG_SERVER_PWD=dev-pwd
API=https://localhost:8443
HEALTH=http://localhost:7000/actuator/health
EVENTS=http://localhost:7000/actuator/circuitbreakerevents/product/STATE_TRANSITION

PASS=0; FAIL=0
assertEqual() { local exp="$1" act="$2" lbl="$3"
  if [[ "$exp" == "$act" ]]; then echo "    OK   [$lbl] $act"; PASS=$((PASS+1))
  else echo "    FAIL [$lbl] expected '$exp' got '$act'"; FAIL=$((FAIL+1)); fi; }
assertHttp() { local exp="$1" act="$2" lbl="$3"
  if [[ "$exp" == "$act" ]]; then echo "    OK   [$lbl] HTTP $act"; PASS=$((PASS+1))
  else echo "    FAIL [$lbl] expected HTTP $exp got $act"; FAIL=$((FAIL+1)); fi; }
state() { curl -sk $HEALTH | jq -r '.components.circuitBreakers.details.product.details.state'; }
ev()    { curl -sk $EVENTS | jq -r ".circuitBreakerEvents[$1].stateTransition"; }

{
echo "===== 0. RESET THE BREAKER (restart the composite: its breaker starts CLOSED) ====="
fuser -k 7000/tcp >/dev/null 2>&1
sleep 8
nohup java -jar microservices/product-composite-service/build/libs/*.jar --server.port=7000 > /tmp/c13d_composite.log 2>&1 &
sleep 35
echo "  composite: port=$(ss -ltn 2>/dev/null|grep -c ':7000') Started=$(grep -c 'Started.*Application' /tmp/c13d_composite.log)"
echo "  breaker state after restart: $(state)"
echo

TOK=$(curl -sk -s https://writer:secret@localhost:8443/oauth/token -d grant_type=password -d username=magnus -d password=password | jq -r .access_token)
echo "===== 1. TOKEN from the gateway (8443), not the auth server (9999) ====="
echo "    token: $([ -n "$TOK" ] && [ "$TOK" != "null" ] && echo acquired || echo FAILED)"
echo

echo "===== 2. THE BOOK'S testCircuitBreaker(), with the book's product IDs ====="
echo "  2a. breaker starts CLOSED"
assertEqual "CLOSED" "$(state)" "state before any slow call"

echo "  2b. three slow calls (?delay=3 vs the 2000ms timeout) -> 500 + timeout message"
for ((n=0; n<3; n++)); do
  CODE=$(curl -sk -o /tmp/resp.json -w '%{http_code}' -H "Authorization: Bearer $TOK" "$API/product-composite/2?delay=3")
  MSG=$(jq -r .message /tmp/resp.json 2>/dev/null)
  assertHttp 500 "$CODE" "slow call $((n+1))"
  assertEqual "Did not observe any item or terminal signal within 2000ms" "${MSG:0:57}" "slow call $((n+1)) message"
done

echo "  2c. breaker OPEN: slow call fails fast -> 200 + fallback"
CODE=$(curl -sk -o /tmp/resp.json -w '%{http_code}' -H "Authorization: Bearer $TOK" "$API/product-composite/2?delay=3")
assertHttp 200 "$CODE" "slow call while OPEN"
assertEqual "Fallback product2" "$(jq -r .name /tmp/resp.json 2>/dev/null)" "fallback body"

echo "  2d. breaker OPEN: a NORMAL call also returns the fallback"
CODE=$(curl -sk -o /tmp/resp.json -w '%{http_code}' -H "Authorization: Bearer $TOK" "$API/product-composite/2")
assertHttp 200 "$CODE" "normal call while OPEN"
assertEqual "Fallback product2" "$(jq -r .name /tmp/resp.json 2>/dev/null)" "fallback body (normal)"

echo "  2e. fallback returns 404 for PROD_ID_NOT_FOUND=13"
CODE=$(curl -sk -o /tmp/resp.json -w '%{http_code}' -H "Authorization: Bearer $TOK" "$API/product-composite/13")
assertHttp 404 "$CODE" "fallback 404"
assertEqual "Product Id: 13 not found in fallback cache!" "$(jq -r .message /tmp/resp.json 2>/dev/null)" "fallback 404 message"

echo "    breaker state now: $(state)"
echo "  2f. wait 10s for HALF_OPEN"
sleep 10
assertEqual "HALF_OPEN" "$(state)" "state after 10s"

echo "  2g. three normal calls close it and reach the real DB"
for ((n=0; n<3; n++)); do
  CODE=$(curl -sk -o /tmp/resp.json -w '%{http_code}' -H "Authorization: Bearer $TOK" "$API/product-composite/2")
  assertHttp 200 "$CODE" "recovery call $((n+1))"
  assertEqual "product name C" "$(jq -r .name /tmp/resp.json 2>/dev/null)" "recovery call $((n+1)) body"
done
assertEqual "CLOSED" "$(state)" "state after recovery"

echo "  2h. state-transition history"
assertEqual "CLOSED_TO_OPEN"      "$(ev -3)" "transition -3"
assertEqual "OPEN_TO_HALF_OPEN"   "$(ev -2)" "transition -2"
assertEqual "HALF_OPEN_TO_CLOSED" "$(ev -1)" "transition -1"

echo
echo "===== RESULT: $PASS passed, $FAIL failed ====="
} > $OUT 2>&1
echo "PASS=$PASS FAIL=$FAIL LINES=$(wc -l < $OUT)"
