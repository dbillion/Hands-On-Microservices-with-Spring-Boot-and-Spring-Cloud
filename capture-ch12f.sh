#!/bin/bash
# Ch12 attempt 3: fix the incomplete restart. Attempt 2 freed 7000-7003/8443 but
# NOT 8761, so the eureka server from attempt 1 kept running with the cipher-hex
# password baked in while clients now send the decrypted 'p' -> 401 registration.
# Every port the stack owns must be freed before restarting any of it.
W=/workspaces/Hands-On-Microservices-with-Spring-Boot-and-Spring-Cloud
OUT=/tmp/ch12-final.txt
cd $W/Chapter12 || exit 1
source /usr/local/sdkman/bin/sdkman-init.sh >/dev/null 2>&1
{
echo "===== FIX 3: free 8761 too, so eureka restarts with decrypted config ====="
echo "  Attempt 2 freed 7000-7003 and 8443 only. Eureka on 8761 was still the"
echo "  attempt-1 process holding password = cipher-hex."
for p in 7000 7001 7002 7003 8443 8761 9999 8888; do
  fuser -k $p/tcp >/dev/null 2>&1
done
sleep 10
echo "  ports still bound after kill: $(ss -ltn 2>/dev/null | grep -cE ':(7000|7001|7002|7003|8443|8761|9999|8888)')"
echo

echo "===== START: config server, then eureka, then clients ====="
export ENCRYPT_KEY=my-very-secure-encrypt-key
export SPRING_SECURITY_USER_NAME=dev-usr
export SPRING_SECURITY_USER_PASSWORD=dev-pwd
SPRING_PROFILES_ACTIVE=native nohup java -jar spring-cloud/config-server/build/libs/*.jar > /tmp/cfg12c.log 2>&1 &
sleep 40
echo "  config-server Started: $(grep -c 'Started ConfigServerApplication' /tmp/cfg12c.log)  port 8888: $(ss -ltn 2>/dev/null|grep -c ':8888')"
export CONFIG_SERVER_USR=dev-usr CONFIG_SERVER_PWD=dev-pwd

nohup java -jar spring-cloud/eureka-server/build/libs/*.jar > /tmp/eu12c.log 2>&1 &
sleep 25
echo "  eureka Started: $(grep -c 'Started.*Application' /tmp/eu12c.log)  port 8761: $(ss -ltn 2>/dev/null|grep -c ':8761')"
echo "  config server serves eureka-password decrypted (not hex):"
curl -s -u dev-usr:dev-pwd http://localhost:8888/application/default \
  | grep -oE '"app.eureka-password":"[^"]*"' | sed 's/^/    /'
echo "  eureka now accepts u:p: $(curl -s -o /dev/null -w '%{http_code}' -u u:p localhost:8761/eureka/apps)"
echo "  eureka with wrong password: $(curl -s -o /dev/null -w '%{http_code}' -u u:wrong localhost:8761/eureka/apps)"

nohup java -jar spring-cloud/authorization-server/build/libs/*.jar --server.port=9999 > /tmp/auth12c.log 2>&1 &
sleep 35
echo "  auth-server Started: $(grep -c 'Started.*Application' /tmp/auth12c.log)"
nohup java -jar spring-cloud/gateway/build/libs/*.jar > /tmp/gw12c.log 2>&1 &
sleep 35
echo "  gateway Started: $(grep -c 'Started.*Application' /tmp/gw12c.log)"
for s in product-service review-service recommendation-service product-composite-service; do
  case $s in product-composite-service) f=product-composite ;; *) f=${s%-service} ;; esac
  P=$(grep -m1 'server.port' "config-repo/$f.yml" | cut -d: -f2 | tr -d ' ')
  nohup java -jar microservices/$s/build/libs/*.jar --server.port=$P > /tmp/c12c_$s.log 2>&1 &
done
sleep 90
for s in product-service review-service recommendation-service product-composite-service; do
  echo "  $s Started: $(grep -c 'Started.*Application' /tmp/c12c_$s.log)  eureka-401: $(grep -c 'status code 401' /tmp/c12c_$s.log)  registration-failed: $(grep -c 'registration failed' /tmp/c12c_$s.log)"
done
echo
echo "  --- eureka registry now (provider's own view, not my inference) ---"
curl -s -u u:p localhost:8761/eureka/apps -H 'Accept: application/json' 2>/dev/null \
  | grep -oE '"name":"[A-Z-]+"' | sort -u | sed 's/^/    /'
echo
echo "  --- composite health through externalised config ---"
curl -s localhost:7000/actuator/health 2>/dev/null | python3 -c "
import sys,json
d=json.load(sys.stdin); print('    overall:', d.get('status'))
print('    discoveryClient services:', d.get('components',{}).get('discoveryComposite',{}).get('components',{}).get('discoveryClient',{}).get('details',{}).get('services'))
print('    rabbit:', d.get('components',{}).get('rabbit',{}).get('status'))
" 2>&1 | head -6
echo
echo "===== THE BOOK'S OWN SUITE ====="
echo "  PORT default: $(grep -m1 -E ': *\$\{PORT=' test-em-all.bash | tr -d ' ')"
bash test-em-all.bash 2>&1 | tail -32
} > $OUT 2>&1
echo "LINES=$(wc -l < $OUT)"
