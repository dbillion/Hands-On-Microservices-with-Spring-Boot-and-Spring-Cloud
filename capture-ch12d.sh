#!/bin/bash
# Ch12: centralised configuration via Spring Cloud Config Server.
# Difference from ch11: services no longer carry application.yml; they fetch
# config from :8888 and need CONFIG_SERVER_USR/PWD + ENCRYPT_KEY.
W=/workspaces/Hands-On-Microservices-with-Spring-Boot-and-Spring-Cloud
OUT=/tmp/ch12-run.txt
cd $W || exit 1
{

echo "===== INFRA: recreate from scratch (codespace rebooted: /tmp wiped, containers exited) ====="
echo "  Codespace reboot evidence: ch7kafka/ch7rabbit/ch7zk/ch6mysql/ch6mongo all Exited,"
echo "  ss shows no listening port, /tmp empty. Containers are RECREATED, not started,"
echo "  because a recycled machine has no container state to resume."
sudo docker rm -f ch6mongo ch6mysql ch7zk ch7kafka ch7rabbit >/dev/null 2>&1
sudo docker run -d --name ch6mongo -p 27017:27017 mongo:3.6.9 mongod --smallfiles >/dev/null 2>&1
sudo docker run -d --name ch6mysql -p 3306:3306 -e MYSQL_ROOT_PASSWORD=rootpwd \
  -e MYSQL_DATABASE=review-db -e MYSQL_USER=user -e MYSQL_PASSWORD=pwd mysql:5.7 >/dev/null 2>&1
sudo docker run -d --name ch7zk -p 2181:2181 -e ZOOKEEPER_CLIENT_PORT=2181 \
  confluentinc/cp-zookeeper:5.5.0 >/dev/null 2>&1
sudo docker run -d --name ch7rabbit -p 5672:5672 -p 15672:15672 \
  rabbitmq:3.8-management-alpine >/dev/null 2>&1
sleep 20
sudo docker run -d --name ch7kafka -p 9092:9092 --link ch7zk:zookeeper \
  -e KAFKA_ZOOKEEPER_CONNECT=zookeeper:2181 \
  -e KAFKA_ADVERTISED_LISTENERS=PLAINTEXT://localhost:9092 \
  -e KAFKA_LISTENERS=PLAINTEXT://0.0.0.0:9092 \
  -e KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR=1 \
  confluentinc/cp-kafka:5.5.0 >/dev/null 2>&1
sleep 55
echo "  containers: $(sudo docker ps --format '{{.Names}}' | tr '\n' ' ')"
echo "  ports listening: 3306=$(ss -ltn 2>/dev/null|grep -c ':3306') 27017=$(ss -ltn 2>/dev/null|grep -c ':27017') 9092=$(ss -ltn 2>/dev/null|grep -c ':9092') 5672=$(ss -ltn 2>/dev/null|grep -c ':5672') 2181=$(ss -ltn 2>/dev/null|grep -c ':2181')"
echo "  mysql ready for connections: $(sudo docker logs ch6mysql 2>&1 | grep -c 'ready for connections')"
echo

echo "===== CREDENTIALS: they ARE in the repo (dotfile .env), contrary to the earlier run ====="
echo "  Earlier FINDINGS said the three vars were 'not in the repository'. They are, in"
echo "  Chapter12/.env, which 'ls' without -a does not show and docker-compose auto-loads:"
cd $W/Chapter12 && cat .env | sed 's/^/    /'
echo

echo "===== START CONFIG SERVER (native profile, user store + encrypt key supplied) ====="
cd $W/Chapter12 || exit 1
source /usr/local/sdkman/bin/sdkman-init.sh >/dev/null 2>&1
# The server has SecurityConfig requiring httpBasic but no user store of its own,
# and no reference to CONFIG_SERVER_USR. Spring Boot therefore falls back to a
# generated password. Supply the user explicitly so it matches what the clients'
# bootstrap.yml sends (CONFIG_SERVER_USR / CONFIG_SERVER_PWD from .env).
export SPRING_PROFILES_ACTIVE=native
export SPRING_SECURITY_USER_NAME=dev-usr
export SPRING_SECURITY_USER_PASSWORD=dev-pwd
export CONFIG_SERVER_ENCRYPT_KEY=my-very-secure-encrypt-key
nohup java -jar spring-cloud/config-server/build/libs/*.jar > /tmp/cfg12.log 2>&1 &
sleep 40
echo "  Started lines:        $(grep -c 'Started ConfigServerApplication' /tmp/cfg12.log)"
echo "  port 8888 listening:  $(ss -ltn 2>/dev/null | grep -c ':8888')"
echo "  generated password?:  $(grep -c 'Using generated security password' /tmp/cfg12.log)"
echo "  ABORT/ERROR lines:    $(grep -cE 'APPLICATION FAILED TO START|Git URI' /tmp/cfg12.log)"
echo
echo "  --- config server auth behaviour (expected 401 then 200) ---"
curl -s -o /dev/null -w "    no credentials        -> HTTP=%{http_code}\n" http://localhost:8888/product/default
curl -s -o /dev/null -w "    dev-usr / dev-pwd     -> HTTP=%{http_code}\n" -u dev-usr:dev-pwd http://localhost:8888/product/default
curl -s -o /dev/null -w "    wrong password        -> HTTP=%{http_code}\n" -u dev-usr:wrong http://localhost:8888/product/default
echo
echo "  --- decryption of {cipher} values (the encrypt key actually working) ---"
echo "    product/default, encrypted fields only:"
curl -s -u dev-usr:dev-pwd http://localhost:8888/product/default \
  | grep -E 'rabbitmq|password|username' | sed 's/^/    /' | head -8
echo

echo "===== START eureka, auth-server, gateway, then the four microservices ====="
cd $W/Chapter12 || exit 1
export CONFIG_SERVER_USR=dev-usr
export CONFIG_SERVER_PWD=dev-pwd
nohup java -jar spring-cloud/eureka-server/build/libs/*.jar > /tmp/eu12.log 2>&1 &
sleep 22
echo "  eureka Started:    $(grep -c 'Started.*Application' /tmp/eu12.log)"
nohup java -jar spring-cloud/authorization-server/build/libs/*.jar --server.port=9999 > /tmp/auth12.log 2>&1 &
sleep 35
echo "  auth-server Started: $(grep -c 'Started.*Application' /tmp/auth12.log)"
nohup java -jar spring-cloud/gateway/build/libs/*.jar > /tmp/gw12.log 2>&1 &
sleep 35
echo "  gateway(8443) Started: $(grep -c 'Started.*Application' /tmp/gw12.log)"
for s in product-service review-service recommendation-service product-composite-service; do
  case $s in
    product-composite-service) f=product-composite ;;
    *) f=${s%-service} ;;
  esac
  P=$(grep -m1 'server.port' "config-repo/$f.yml" | cut -d: -f2 | tr -d ' ')
  nohup java -jar microservices/$s/build/libs/*.jar --server.port=$P > /tmp/c12_$s.log 2>&1 &
done
sleep 80
for s in product-service review-service recommendation-service product-composite-service; do
  echo "  $s Started: $(grep -c 'Started.*Application' /tmp/c12_$s.log)  401-from-config: $(grep -c '401' /tmp/c12_$s.log)"
done
echo
echo "  --- which ports are actually bound ---"
ss -ltn 2>/dev/null | grep -oE ':(7000|7001|7002|7003|8443|8761|9999|8888)' | sort -u | sed 's/^/    /'
echo

echo "===== THE BOOK'S OWN SUITE ====="
echo "  test-em-all.bash PORT default (read from the script, not assumed):"
grep -m1 -E ': *\$\{PORT=' test-em-all.bash | sed 's/^/    /'
bash test-em-all.bash 2>&1 | tail -40
echo
echo "===== CROSS-SERVICE AGGREGATION THROUGH EXTERNALISED CONFIG ====="
curl -s -w "\n    /product-composite/1 -> HTTP=%{http_code}\n" localhost:7000/product-composite/1 | head -12
echo "===== SERVICE DISCOVERY (eureka still wired) ====="
curl -s localhost:8761/eureka/apps -H 'Accept: application/json' 2>/dev/null | grep -o '"name":"[A-Z]*"' | sort -u | sed 's/^/    registered: /'

} > $OUT 2>&1
echo "LINES=$(wc -l < $OUT)"
