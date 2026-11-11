#!/bin/bash
# Ch12 close-out: the one gap in the run — the runbook reused jars from an earlier
# build without running ./gradlew build in this run. Run the real build so the
# runbook's build step is evidence, not an assumption.
W=/workspaces/Hands-On-Microservices-with-Spring-Boot-and-Spring-Cloud
OUT=/tmp/ch12-build.txt
cd $W/Chapter12 || exit 1
source /usr/local/sdkman/bin/sdkman-init.sh >/dev/null 2>&1
{
echo "===== BUILD (the runbook step that was previously skipped) ====="
echo "  wrapper: $(grep distributionUrl gradle/wrapper/gradle-wrapper.properties | grep -oE 'gradle-[0-9.]+-bin.zip')"
echo "  java:    $(java -version 2>&1 | head -1)"
./gradlew build 2>&1 | tail -12
echo
echo "  jars produced by THIS build:"
find . -name '*.jar' -path '*/build/libs/*' -newermt '-10 minutes' 2>/dev/null \
  | sed 's|^\./|    |' | sort
echo
echo "===== SUITE RERUN AGAINST THE FRESHLY BUILT JARS ====="
echo "  (the stack started in capture-ch12f.sh is still running; the build"
echo "   overwrote the jars on disk but the running JVMs hold the old bytes,"
echo "   so a restart is needed for this to be a fair test of the new jars.)"
for p in 7000 7001 7002 7003 8443 8761 9999 8888; do fuser -k $p/tcp >/dev/null 2>&1; done
sleep 10
export ENCRYPT_KEY=my-very-secure-encrypt-key
export SPRING_SECURITY_USER_NAME=dev-usr SPRING_SECURITY_USER_PASSWORD=dev-pwd
export CONFIG_SERVER_USR=dev-usr CONFIG_SERVER_PWD=dev-pwd
SPRING_PROFILES_ACTIVE=native nohup java -jar spring-cloud/config-server/build/libs/*.jar > /tmp/b12cfg.log 2>&1 &
sleep 40
nohup java -jar spring-cloud/eureka-server/build/libs/*.jar > /tmp/b12eu.log 2>&1 &
sleep 25
nohup java -jar spring-cloud/authorization-server/build/libs/*.jar --server.port=9999 > /tmp/b12auth.log 2>&1 &
sleep 30
nohup java -jar spring-cloud/gateway/build/libs/*.jar > /tmp/b12gw.log 2>&1 &
sleep 30
for s in product-service review-service recommendation-service product-composite-service; do
  case $s in product-composite-service) f=product-composite ;; *) f=${s%-service} ;; esac
  P=$(grep -m1 'server.port' "config-repo/$f.yml" | cut -d: -f2 | tr -d ' ')
  nohup java -jar microservices/$s/build/libs/*.jar --server.port=$P > /tmp/b12_$s.log 2>&1 &
done
sleep 90
for s in product-service review-service recommendation-service product-composite-service; do
  echo "  $s Started: $(grep -c 'Started.*Application' /tmp/b12_$s.log)"
done
echo "  eureka: $(curl -s -u u:p localhost:8761/eureka/apps -H 'Accept: application/json' 2>/dev/null | grep -oE '\"name\":\"[A-Z-]+\"' | sort -u | tr '\n' ' ')"
echo
bash test-em-all.bash 2>&1 | grep -E 'Test OK|All tests OK|End, all|FAIL|Wait for' | tail -25
} > $OUT 2>&1
echo "LINES=$(wc -l < $OUT)"
