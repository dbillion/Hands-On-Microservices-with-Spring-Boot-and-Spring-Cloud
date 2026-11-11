#!/bin/bash
# Ch13: resilience — Resilience4j retry + circuit breaker on the composite's
# product call. Same config-server recipe as ch12 (ENCRYPT_KEY, native profile,
# explicit security user). Verified claim: the breaker actually trips when the
# product service is unavailable, and health reports it.
W=/workspaces/Hands-On-Microservices-with-Spring-Boot-and-Spring-Cloud
OUT=/tmp/ch13-run.txt
cd $W || exit 1
{
echo "===== 0. INFRA (containers from ch12 are already running) ====="
echo "  containers: $(sudo docker ps --format '{{.Names}}' | tr '\n' ' ')"
echo "  ports: 3306=$(ss -ltn 2>/dev/null|grep -c ':3306') 27017=$(ss -ltn 2>/dev/null|grep -c ':27017') 9092=$(ss -ltn 2>/dev/null|grep -c ':9092') 5672=$(ss -ltn 2>/dev/null|grep -c ':5672')"
echo

echo "===== 1. FREE EVERY PORT THE STACK OWNS (ch12's lesson) ====="
for p in 7000 7001 7002 7003 8443 8761 9999 8888; do fuser -k $p/tcp >/dev/null 2>&1; done
sleep 12
echo "  ports still bound: $(ss -ltn 2>/dev/null | grep -cE ':(7000|7001|7002|7003|8443|8761|9999|8888)')"
echo

echo "===== 2. BUILD ====="
cd $W/Chapter13 || exit 1
source /usr/local/sdkman/bin/sdkman-init.sh >/dev/null 2>&1
echo "  wrapper: $(grep -oE 'gradle-[0-9.]+-bin.zip' gradle/wrapper/gradle-wrapper.properties)  java: $(java -version 2>&1 | head -1)"
./gradlew build 2>&1 | grep -E 'BUILD SUCCESSFUL|BUILD FAILED|actionable tasks'
echo

echo "===== 3. CH13's NEW CONFIG (resilience) — read from source, not assumed ====="
echo "  resilience4j + retry deps present: $(grep -c 'resilience4j' microservices/product-composite-service/build.gradle)"
grep -A4 'resilience4j.circuitbreaker' config-repo/product-composite.yml | head -6 | sed 's/^/    /'
grep -A3 'resilience4j.retry' config-repo/product-composite.yml | head -4 | sed 's/^/    /'
grep 'timeoutSec' config-repo/product-composite.yml | sed 's/^/    /'
grep -n 'CircuitBreaker\|retry\|@TimeLimiter' microservices/product-composite-service/src/main/java/se/magnus/microservices/composite/ProductCompositeIntegration.java 2>/dev/null | head -8 | sed 's/^/    code: /'
echo

echo "===== 4. START: config server, eureka, auth, gateway, 4 services ====="
cd $W/Chapter13 || exit 1
export ENCRYPT_KEY=my-very-secure-encrypt-key
export SPRING_SECURITY_USER_NAME=dev-usr SPRING_SECURITY_USER_PASSWORD=dev-pwd
SPRING_PROFILES_ACTIVE=native nohup java -jar spring-cloud/config-server/build/libs/*.jar > /tmp/c13cfg.log 2>&1 &
sleep 40
echo "  config-server Started: $(grep -c 'Started ConfigServerApplication' /tmp/c13cfg.log)  8888: $(ss -ltn 2>/dev/null|grep -c ':8888')"
export CONFIG_SERVER_USR=dev-usr CONFIG_SERVER_PWD=dev-pwd
nohup java -jar spring-cloud/eureka-server/build/libs/*.jar > /tmp/eu13.log 2>&1 &
sleep 25
echo "  eureka Started: $(grep -c 'Started.*Application' /tmp/eu13.log)  8761: $(ss -ltn 2>/dev/null|grep -c ':8761')"
echo "  cipher decryption check: $(curl -s -u dev-usr:dev-pwd http://localhost:8888/application/default | grep -oE '"app.eureka-password":"[^"]*"')"
nohup java -jar spring-cloud/authorization-server/build/libs/*.jar --server.port=9999 > /tmp/auth13.log 2>&1 &
sleep 35
nohup java -jar spring-cloud/gateway/build/libs/*.jar > /tmp/gw13.log 2>&1 &
sleep 35
for s in product-service review-service recommendation-service product-composite-service; do
  case $s in product-composite-service) f=product-composite ;; *) f=${s%-service} ;; esac
  P=$(grep -m1 'server.port' "config-repo/$f.yml" | cut -d: -f2 | tr -d ' ')
  nohup java -jar microservices/$s/build/libs/*.jar --server.port=$P > /tmp/c13_$s.log 2>&1 &
done
sleep 90
for s in product-service review-service recommendation-service product-composite-service; do
  echo "  $s Started: $(grep -c 'Started.*Application' /tmp/c13_$s.log)  eureka-401: $(grep -c 'status code 401' /tmp/c13_$s.log)"
done
echo "  eureka registry: $(curl -s -u u:p localhost:8761/eureka/apps -H 'Accept: application/json' 2>/dev/null | grep -oE '\"name\":\"[A-Z-]+\"' | sort -u | tr '\n' ' ')"
echo

echo "===== 5. CIRCUIT BREAKER HEALTH INDICATOR (the chapter's own instrument) ====="
curl -s localhost:7000/actuator/health 2>/dev/null | python3 -c "
import sys,json
d=json.load(sys.stdin)
print('    overall:', d.get('status'))
for k,v in d.get('components',{}).items():
    print(f'    {k}: {v.get(\"status\")}')
" 2>&1 | head -14
echo

echo "===== 6. THE BREAKER UNDER TEST: kill the product service, observe it open ====="
echo "  before: /product-composite/1 through the composite"
TOK=$(curl -sk -u writer:secret https://localhost:9999/oauth/token -d grant_type=password -d username=magnus -d password=password 2>/dev/null | sed -n 's/.*\"access_token\":\"\([^\"]*\)\".*/\1/p')
echo "    token: $([ -n "$TOK" ] && echo acquired || echo FAILED)"
curl -s -o /dev/null -w "    200 expected -> HTTP=%{http_code}\n" -H "Authorization: Bearer $TOK" localhost:7000/product-composite/1
echo "  killing product-service (port 7001)"
fuser -k 7001/tcp >/dev/null 2>&1
sleep 8
echo "  requests while the dependency is down (each retries then trips):"
for i in 1 2 3 4 5 6; do
  CODE=$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $TOK" localhost:7000/product-composite/1)
  echo "    attempt $i -> HTTP=$CODE"
  sleep 2
done
echo "  composite log: circuit breaker + retry evidence"
grep -cE 'CircuitBreaker|Resilience4j|retry' /tmp/c13_product-composite-service.log | sed 's/^/    breaker\/retry lines: /'
grep -m6 -oE 'CircuitBreaker .*state: [A-Z_]*|notPermitted[^ ]*|Retry.*[0-9]+ time|GetProduct[^ ]*' /tmp/c13_product-composite-service.log | sed 's/^/    /'
echo
echo "  health now (breaker should be OPEN -> overall DOWN or circuitBreakers component):"
curl -s localhost:7000/actuator/health 2>/dev/null | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
except Exception:
    print('    (health not parseable)'); raise SystemExit
print('    overall:', d.get('status'))
for k,v in d.get('components',{}).items():
    if 'circuit' in k.lower() or 'product' in k.lower() or v.get('status')!='UP':
        print(f'    {k}: {v.get(\"status\")} {json.dumps(v.get(\"details\",{}))[:160]}')
"
echo

echo "===== 7. RECOVERY: restart product, watch the breaker half-open and close ====="
cd $W/Chapter13 || exit 1
nohup java -jar microservices/product-service/build/libs/*.jar --server.port=7001 > /tmp/c13b_product.log 2>&1 &
sleep 35
for i in 1 2 3 4; do
  curl -s -o /dev/null -w "    post-recovery $i -> HTTP=%{http_code}\n" -H "Authorization: Bearer $TOK" localhost:7000/product-composite/1
  sleep 3
done
curl -s localhost:7000/actuator/health 2>/dev/null | python3 -c "
import sys,json
d=json.load(sys.stdin); print('    overall after recovery:', d.get('status'))
"
echo

echo "===== 8. THE BOOK'S OWN SUITE ====="
echo "  PORT default: $(grep -m1 -E ': *\$\{PORT=' test-em-all.bash | tr -d ' ')"
bash test-em-all.bash 2>&1 | grep -E 'Test OK|End, all tests OK|FAIL|Give up' | tail -22
} > $OUT 2>&1
echo "LINES=$(wc -l < $OUT)"
