#!/bin/bash
# Ch12 attempt 2: the encrypt key env var was wrong (CONFIG_SERVER_ENCRYPT_KEY
# is the docker-compose variable name; Spring reads encrypt.key, i.e. ENCRYPT_KEY).
# Without it the server serves the {cipher} hex verbatim, clients authenticate to
# RabbitMQ with that hex, and the binder health goes DOWN.
W=/workspaces/Hands-On-Microservices-with-Spring-Boot-and-Spring-Cloud
OUT=/tmp/ch12-fix.txt
cd $W || exit 1
{
echo "===== FIX 1: correct env var for the encrypt key ====="
echo "  Before: CONFIG_SERVER_ENCRYPT_KEY (a docker-compose variable name)"
echo "  After:  ENCRYPT_KEY               (what Spring binds to encrypt.key)"
echo "  Both values are identical; only the name the server reads differs."
cd $W/Chapter12 || exit 1
source /usr/local/sdkman/bin/sdkman-init.sh >/dev/null 2>&1
# kill by port, never by process name (the command line contains 'config-server')
fuser -k 8888/tcp >/dev/null 2>&1
sleep 5
export ENCRYPT_KEY=my-very-secure-encrypt-key
export SPRING_SECURITY_USER_NAME=dev-usr
export SPRING_SECURITY_USER_PASSWORD=dev-pwd
SPRING_PROFILES_ACTIVE=native nohup java -jar spring-cloud/config-server/build/libs/*.jar > /tmp/cfg12b.log 2>&1 &
sleep 40
echo "  Started: $(grep -c 'Started ConfigServerApplication' /tmp/cfg12b.log)  port 8888: $(ss -ltn 2>/dev/null|grep -c ':8888')"
echo
echo "  --- is {cipher} now decrypted when SERVED? (expected: real words, not hex) ---"
echo "  eureka-password / rabbitmq password from /product/default:"
curl -s -u dev-usr:dev-pwd http://localhost:8888/product/default \
  | grep -oE '"(app.eureka-password|spring.rabbitmq.password)":"[^"]*"' | sed 's/^/    /'
echo
echo "  --- positive control: does /decrypt work on the server? ---"
echo -n "bf298f6d5f878b342f9e44bec08cb9ac00b4ce57e98316f030194a225fac89fb" \
  | curl -s -u dev-usr:dev-pwd -X POST --data-binary @- http://localhost:8888/decrypt | sed 's/^/    decrypted: /'
echo

echo "===== FIX 2: restart the four clients so they fetch the decrypted config ====="
cd $W/Chapter12 || exit 1
export CONFIG_SERVER_USR=dev-usr CONFIG_SERVER_PWD=dev-pwd
for p in 7000 7001 7002 7003 8443; do fuser -k $p/tcp >/dev/null 2>&1; done
sleep 8
nohup java -jar spring-cloud/eureka-server/build/libs/*.jar > /tmp/eu12b.log 2>&1 &
sleep 20
nohup java -jar spring-cloud/authorization-server/build/libs/*.jar --server.port=9999 > /tmp/auth12b.log 2>&1 &
sleep 30
nohup java -jar spring-cloud/gateway/build/libs/*.jar > /tmp/gw12b.log 2>&1 &
sleep 30
for s in product-service review-service recommendation-service product-composite-service; do
  case $s in product-composite-service) f=product-composite ;; *) f=${s%-service} ;; esac
  P=$(grep -m1 'server.port' "config-repo/$f.yml" | cut -d: -f2 | tr -d ' ')
  nohup java -jar microservices/$s/build/libs/*.jar --server.port=$P > /tmp/c12b_$s.log 2>&1 &
done
sleep 80
for s in product-service review-service recommendation-service product-composite-service; do
  echo "  $s Started: $(grep -c 'Started.*Application' /tmp/c12b_$s.log)  ACCESS_REFUSED: $(grep -c 'ACCESS_REFUSED' /tmp/c12b_$s.log)  401-config: $(grep -c '401' /tmp/c12b_$s.log)"
done
echo
echo "  --- health, and the binder that was DOWN ---"
curl -s localhost:7000/actuator/health 2>/dev/null | python3 -c "
import sys,json
d=json.load(sys.stdin)
print('    overall:', d.get('status'))
for k,v in d.get('components',{}).items():
    print(f'    {k}: {v.get(\"status\")}')
" 2>/dev/null || echo "    (health not parseable)"
echo
echo "===== THE BOOK'S OWN SUITE ====="
echo "  PORT default read from the script: $(grep -m1 -E ': *\$\{PORT=' test-em-all.bash | tr -d ' ')"
bash test-em-all.bash 2>&1 | tail -30
echo
echo "===== CROSS-SERVICE AGGREGATION (composite direct, needs bearer from ch11) ====="
TOK=$(curl -sk -u writer:secret https://localhost:9999/oauth/token -d grant_type=password -d username=magnus -d password=password 2>/dev/null | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p')
echo "  token acquired: $([ -n "$TOK" ] && echo yes || echo NO)"
if [ -n "$TOK" ]; then
  curl -s -w "\n    /product-composite/1 -> HTTP=%{http_code}\n" -H "Authorization: Bearer $TOK" localhost:7000/product-composite/1 | head -14
fi
echo
echo "===== EVIDENCE: services registered in eureka under externalised config ====="
curl -s -u u:p localhost:8761/eureka/apps -H 'Accept: application/json' 2>/dev/null | grep -o '"name":"[A-Z-]*"' | sort -u | sed 's/^/    /'
} > $OUT 2>&1
echo "LINES=$(wc -l < $OUT)"
