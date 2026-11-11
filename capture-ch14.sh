#!/bin/bash
# Ch14: distributed tracing — Spring Cloud Sleuth + Zipkin over RabbitMQ.
# The book's own test-em-all.bash does NOT verify tracing, so the real evidence
# is: run Zipkin, exercise a composite call, and confirm spans from multiple
# services land in the SAME trace.
# Zipkin runs with --network host so RABBIT_ADDRESSES=127.0.0.1 reaches the
# rabbit container the same way the services do.
W=/workspaces/Hands-On-Microservices-with-Spring-Boot-and-Spring-Cloud
OUT=/tmp/ch14-run.txt
cd $W/Chapter14 || exit 1
source /usr/local/sdkman/bin/sdkman-init.sh >/dev/null 2>&1
{
echo "===== 0. INFRA + ZIPKIN ====="
echo "  containers: $(sudo docker ps --format '{{.Names}}' | tr '\n' ' ')"
echo "  ports: 5672=$(ss -ltn 2>/dev/null|grep -c ':5672') 9092=$(ss -ltn 2>/dev/null|grep -c ':9092')"
echo "  starting Zipkin (RabbitMQ span collector, in-memory storage)"
sudo docker rm -f ch14zipkin >/dev/null 2>&1
sudo docker run -d --name ch14zipkin --network host \
  -e STORAGE_TYPE=mem -e RABBIT_ADDRESSES=127.0.0.1 openzipkin/zipkin:2.12.9 >/dev/null 2>&1
sleep 25
echo "  zipkin container: $(sudo docker inspect -f '{{.State.Status}}' ch14zipkin 2>/dev/null)  9411: $(ss -ltn 2>/dev/null|grep -c ':9411')"
echo "  zipkin health: $(curl -s -m 10 http://localhost:9411/health | tr -d '\n')"
echo

echo "===== 1. FREE EVERY PORT THE STACK OWNS ====="
for p in 7000 7001 7002 7003 8443 8761 9999 8888; do fuser -k $p/tcp >/dev/null 2>&1; done
sleep 12
echo "  ports still bound: $(ss -ltn 2>/dev/null | grep -cE ':(7000|7001|7002|7003|8443|8761|9999|8888)')"
echo

echo "===== 2. BUILD ====="
echo "  wrapper: $(grep -oE 'gradle-[0-9.]+-bin.zip' gradle/wrapper/gradle-wrapper.properties)  java: $(java -version 2>&1 | head -1)"
./gradlew build 2>&1 | grep -E 'BUILD SUCCESSFUL|BUILD FAILED|actionable tasks'
echo

echo "===== 3. CH14's TRACING CONFIG (read from source, not assumed) ====="
grep -E 'zipkin|sleuth|sampler' config-repo/application.yml | grep -v '^#' | sed 's/^/    /'
echo "  deps in composite: $(grep -cE 'sleuth|zipkin' microservices/product-composite-service/build.gradle)"
echo "  modules carrying sleuth+zipkin: $(grep -rl 'spring-cloud-starter-zipkin' --include=build.gradle . | wc -l)"
echo

echo "===== 4. START: config server, eureka, auth, gateway, 4 services ====="
cd $W/Chapter14 || exit 1
export ENCRYPT_KEY=my-very-secure-encrypt-key
export SPRING_SECURITY_USER_NAME=dev-usr SPRING_SECURITY_USER_PWD_PLACEHOLDER=1
export SPRING_SECURITY_USER_PASSWORD=dev-pwd
SPRING_PROFILES_ACTIVE=native nohup java -jar spring-cloud/config-server/build/libs/*.jar > /tmp/c14cfg.log 2>&1 &
sleep 40
echo "  config-server Started: $(grep -c 'Started ConfigServerApplication' /tmp/c14cfg.log)"
export CONFIG_SERVER_USR=dev-usr CONFIG_SERVER_PWD=dev-pwd
nohup java -jar spring-cloud/eureka-server/build/libs/*.jar > /tmp/eu14.log 2>&1 &
sleep 25
nohup java -jar spring-cloud/authorization-server/build/libs/*.jar --server.port=9999 > /tmp/auth14.log 2>&1 &
sleep 35
nohup java -jar spring-cloud/gateway/build/libs/*.jar > /tmp/gw14.log 2>&1 &
sleep 35
for s in product-service review-service recommendation-service product-composite-service; do
  case $s in product-composite-service) f=product-composite ;; *) f=${s%-service} ;; esac
  P=$(grep -m1 'server.port' "config-repo/$f.yml" | cut -d: -f2 | tr -d ' ')
  nohup java -jar microservices/$s/build/libs/*.jar --server.port=$P > /tmp/c14_$s.log 2>&1 &
done
sleep 90
for s in product-service review-service recommendation-service product-composite-service; do
  echo "  $s Started: $(grep -c 'Started.*Application' /tmp/c14_$s.log)"
done
echo "  eureka: $(curl -sk -u u:p localhost:8761/eureka/apps -H 'Accept: application/json' 2>/dev/null | grep -oE '\"name\":\"[A-Z-]+\"' | sort -u | tr '\n' ' ')"
echo "  services reporting sleuth/browser: $(grep -lc 'Sleuth' /tmp/c14_*.log 2>/dev/null | wc -l)/4 composite mentions: $(grep -c 'sleuth\|Zipkin' /tmp/c14_product-composite-service.log)"
echo

echo "===== 5. EXERCISE A COMPOSITE CALL AND SEE IF IT LANDS IN ZIPKIN ====="
TOK=$(curl -sk -s https://writer:secret@localhost:8443/oauth/token -d grant_type=password -d username=magnus -d password=password | jq -r .access_token)
echo "    token: $([ -n "$TOK" ] && [ "$TOK" != "null" ] && echo acquired || echo FAILED)"
echo "  response headers from a composite call (look for Trace-Id):"
curl -sk -D /tmp/hdrs.txt -o /dev/null -H "Authorization: Bearer $TOK" "https://localhost:8443/product-composite/2"
grep -iE 'trace|span|parent|x-b3|correlation' /tmp/hdrs.txt | sed 's/^/    /'
echo "  zipkin trace count BEFORE the call: $(curl -s -m 10 'http://localhost:9411/api/v2/traces?limit=1' | jq 'length' 2>/dev/null)"
echo "  making the call with the book's delay so it takes real work:"
curl -sk -o /dev/null -w "    composite/?delay=1 -> HTTP=%{http_code}\n" -H "Authorization: Bearer $TOK" "https://localhost:8443/product-composite/2?delay=1"
sleep 12
TRACES=$(curl -s -m 15 'http://localhost:9411/api/v2/traces?limit=5')
echo "  zipkin traces AFTER: $(echo "$TRACES" | jq 'length' 2>/dev/null)"
echo "  services appearing in the newest trace:"
echo "$TRACES" | jq -r '.[0] // [] | sort_by(.timestamp) | .[] | "    \(.localEndpoint.serviceName // .localEndpoint.serviceName // "?")  span=\(.name)"' 2>/dev/null | sort -u | head -14
echo "  distinct service names in that one trace:"
echo "$TRACES" | jq -r '[.[0][]?.localEndpoint.serviceName] | unique | join(", ")' 2>/dev/null
echo "  trace ids present: $(echo "$TRACES" | jq -r '.[0][]?.traceId' 2>/dev/null | sort -u | head -3 | tr '\n' ' ')"
echo

echo "===== 6. THE BOOK'S OWN SUITE (does not cover tracing) ====="
sed 's|\$EXEC wget product-composite:8080\([^ ]*\) -qO -|curl -sf http://localhost:7000\1|g' test-em-all.bash > test-em-all-jarrun.bash
HOST=localhost PORT=8443 bash test-em-all-jarrun.bash > /tmp/ch14-suite.txt 2>&1
echo "  assertions OK: $(grep -cE '^Test OK' /tmp/ch14-suite.txt)"
echo "  failures: $(grep -cE 'FAILED|ABORT' /tmp/ch14-suite.txt)"
grep -E 'FAILED|ABORT|End, all tests OK' /tmp/ch14-suite.txt | sed 's/^/    /'
echo

echo "===== 7. TRACE CORRELATION ACROSS SERVICES (the chapter's real claim) ====="
echo "  One trace, spans by service (a single request must traverse the composite"
echo "  and its three dependencies):"
echo "$TRACES" | jq -r '.[0] // [] | group_by(.localEndpoint.serviceName) | map("    \(.[0].localEndpoint.serviceName): \(length) span(s)") | .[]' 2>/dev/null
echo "  total spans in newest trace: $(echo "$TRACES" | jq -r '[.[0][]?] | length' 2>/dev/null)"
} > $OUT 2>&1
echo "LINES=$(wc -l < $OUT)"
