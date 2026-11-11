#!/bin/bash
# Ch13 breaker verification, using the BOOK'S OWN assertions verbatim from
# testCircuitBreaker() in test-em-all.bash, with two substitutions required by
# running from jars rather than docker-compose:
#   1. $EXEC wget product-composite:8080/... -> curl -s localhost:7000/...
#      (the book's EXEC is `docker run --rm -it --network=my-network alpine`;
#      that network only exists under docker-compose, which this run does not
#      use)
#   2. the bearer token comes from the gateway (8443), not the auth-server
#      directly (9999) -- 9999 returns an empty body for the password grant,
#      8443 returns a JWT. $HOST:$PORT in the book is the gateway.
W=/workspaces/Hands-On-Microservices-with-Spring-Boot-and-Spring-Cloud
OUT=/tmp/ch13-breaker.txt
cd $W/Chapter13 || exit 1
source /usr/local/sdkman/bin/sdkman-init.sh >/dev/null 2>&1
API=https://localhost:8443
HEALTH=http://localhost:7000/actuator/health
EVENTS=http://localhost:7000/actuator/circuitbreakerevents/product/STATE_TRANSITION

# the book's assert helpers, restated so a failure cannot pass silently
PASS=0; FAIL=0
assertEqual() { local exp="$1" act="$2" lbl="$3"
  if [[ "$exp" == "$act" ]]; then echo "    OK   [$lbl] $act"; PASS=$((PASS+1))
  else echo "    FAIL [$lbl] expected '$exp' got '$act'"; FAIL=$((FAIL+1)); fi; }
assertHttp() { local exp="$1" act="$2" lbl="$3"
  if [[ "$exp" == "$act" ]]; then echo "    OK   [$lbl] HTTP $act"; PASS=$((PASS+1))
  else echo "    FAIL [$lbl] expected HTTP $exp got $act"; FAIL=$((FAIL+1)); fi; }
state() { curl -sk $HEALTH | jq -r '.components.circuitBreakers.details.product.details.state'; }

{
echo "===== 0. STACK MUST BE WHOLE (product service up) BEFORE THE BREAKER TEST ====="
echo "  product-service 7001: $(ss -ltn 2>/dev/null|grep -c ':7001')"
echo "  composite 7000 up:    $(ss -ltn 2>/dev/null|grep -c ':7000')"
if [ "$(ss -ltn 2>/dev/null|grep -c ':7001')" = "0" ]; then
  echo "  product-service is down (the previous capture killed it). Restarting."
  nohup java -jar microservices/product-service/build/libs/*.jar --server.port=7001 > /tmp/c13c_product.log 2>&1 &
  sleep 35
  echo "  product-service now: $(ss -ltn 2>/dev/null|grep -c ':7001')  Started=$(grep -c 'Started.*Application' /tmp/c13c_product.log)"
fi
echo "  eureka sees: $(curl -sk -u u:p $BASE:8761/eureka/apps -H 'Accept: application/json' 2>/dev/null | grep -oE '\"name\":\"[A-Z-]+\"' | sort -u | tr '\n' ' ')"
echo

TOK=$(curl -sk -s https://writer:secret@localhost:8443/oauth/token -d grant_type=password -d username=magnus -d password=password | jq -r .access_token)
echo "===== 1. TOKEN (the fix: gateway, not auth-server) ====="
echo "    token: $([ -n "$TOK" ] && [ "$TOK" != "null" ] && echo acquired || echo FAILED)"
echo

echo "===== 2. THE BOOK'S testCircuitBreaker() ====="
echo "  2a. breaker starts CLOSED (health via composite HTTP:7000, API via gateway HTTPS:8443)"
assertEqual "CLOSED" "$(state)" "state before any slow call"

echo "  2b. three slow calls (?delay=3 vs timeout 2000ms) -> 500 + timeout message"
for ((n=0; n<3; n++)); do
  CODE=$(curl -sk -o /tmp/resp.json -w '%{http_code}' -H "Authorization: Bearer $TOK" "$API/product-composite/2?delay=3")
  MSG=$(jq -r .message /tmp/resp.json 2>/dev/null)
  assertHttp 500 "$CODE" "slow call $((n+1))"
  assertEqual "Did not observe any item or terminal signal within 2000ms" "${MSG:0:57}" "slow call $((n+1)) message"
done

echo "  2c. breaker OPEN: slow call now fails fast -> 200 + fallback"
CODE=$(curl -sk -o /tmp/resp.json -w '%{http_code}' -H "Authorization: Bearer $TOK" "$API/product-composite/2?delay=3")
assertHttp 200 "$CODE" "slow call while OPEN (fail fast)"
assertEqual "Fallback product2" "$(jq -r .name /tmp/resp.json 2>/dev/null)" "fallback body"

echo "  2d. breaker OPEN: a NORMAL call also returns the fallback"
CODE=$(curl -sk -o /tmp/resp.json -w '%{http_code}' -H "Authorization: Bearer $TOK" "$API/product-composite/2")
assertHttp 200 "$CODE" "normal call while OPEN"
assertEqual "Fallback product2" "$(jq -r .name /tmp/resp.json 2>/dev/null)" "fallback body on normal call"

echo "  2e. fallback returns 404 for PROD_ID_NOT_FOUND=13"
CODE=$(curl -sk -o /tmp/resp.json -w '%{http_code}' -H "Authorization: Bearer $TOK" "$API/product-composite/13")
assertHttp 404 "$CODE" "fallback 404"
assertEqual "Product Id: 13 not found in fallback cache!" "$(jq -r .message /tmp/resp.json 2>/dev/null)" "fallback 404 message"

echo "    breaker state now: $(state)"
echo "  2f. wait for HALF_OPEN"
sleep 10
assertEqual "HALF_OPEN" "$(state)" "state after 10s"

echo "  2g. three normal calls close it, and hit the real DB"
for ((n=0; n<3; n++)); do
  CODE=$(curl -sk -o /tmp/resp.json -w '%{http_code}' -H "Authorization: Bearer $TOK" "$API/product-composite/2")
  assertHttp 200 "$CODE" "recovery call $((n+1))"
  assertEqual "product name C" "$(jq -r .name /tmp/resp.json 2>/dev/null)" "recovery call $((n+1)) body"
done
assertEqual "CLOSED" "$(state)" "state after recovery"

echo "  2h. state-transition history (the recorded events)"
assertEqual "CLOSED_TO_OPEN"      "$(curl -sk $EVENTS | jq -r '.circuitBreakerEvents[-3].stateTransition')" "transition -3"
assertEqual "OPEN_TO_HALF_OPEN"   "$(curl -sk $EVENTS | jq -r '.circuitBreakerEvents[-2].stateTransition')" "transition -2"
assertEqual "HALF_OPEN_TO_CLOSED" "$(curl -sk $EVENTS | jq -r '.circuitBreakerEvents[-1].stateTransition')" "transition -1"

echo
echo "===== RESULT: $PASS passed, $FAIL failed ====="
} > $OUT 2>&1
echo "PASS=$PASS FAIL=$FAIL LINES=$(wc -l < $OUT)"
