# Chapter 16 — Using Kubernetes primitives for service discovery

## Summary

Ch16 removes Eureka entirely — the composite's `build.gradle` no longer carries
`spring-cloud-starter-netflix-eureka-client`, and `grep -rl eureka` across
`Chapter16/config-repo` finds nothing. What replaces it is Kubernetes' own DNS
and Services: the manifests under `kubernetes/services/` declare one Deployment
plus one Service per component, kustomised into `base/` + `overlays/dev` +
`overlays/prod`, so the services resolve each other by cluster DNS name instead
of registry lookup. The chapter also keeps the ch12 configuration sourcing
(`spring-cloud-starter-config`) and keeps Sleuth/Zipkin, and adds
`config-client-credentials` as a Secret so the config-server credentials do not
live in a manifest.

## Verdict: PARTIAL — five real defects fixed; still not end-to-end

| Layer reached | State | Evidence |
|---|---|---|
| Cluster | Ready | minikube v1.37.0 on containerd |
| 7 Spring images | Built | all in containerd, `:v1` and `:latest` |
| Tags | Fixed | manifests reference images untagged → `:latest` |
| Secret `config-client-credentials` | Fixed | pods advanced past `CreateContainerConfigError` |
| Image name `auth-server` | Fixed | manifests say `auth-server`, the build dir says `authorization-server` |
| ConfigMap `config-repo` | Fixed | mounts the chapter's 7 real files (1133–3998 bytes each) |
| Secret `config-server-secrets` | Fixed | pods advanced past `FailedMount` |
| **config-server** | **Ready** | `1/1 Running`, serving `/config-repo/application.yml` |
| Stateful deps | Ready | mysql, mongodb, rabbitmq, zipkin `1/1 Running` |
| **7 microservices** | **NOT READY** | Running but looping on config fetch; probe gets connection refused on port 80 |

## Environment actually used

| Tool | Version (pasted) |
|---|---|
| Codespace | `redesigned-guide-9j4x6q96qwjcp7p`, 4 cores / 16 GB RAM / **32 GB storage** |
| Kubernetes | `v1.37.0` on containerd, single-node minikube, `--driver=docker` |
| minikube | `v1.39.0`, `--cpus=4 --memory=7g --disk-size=20g` |
| kubectl | `v1.37.2` |
| Java | `openjdk version "11.0.25" 2024-10-15 LTS` |
| Gradle | `gradle-5.6.4-bin.zip` |

## Runbook — repeat what worked, and know where it stops

```sh
# 0. a cluster (ch15) — free the Spring JVMs and app containers first, ch15's lesson
minikube start --driver=docker --cpus=4 --memory=7g --disk-size=20g
```

```sh
# 1. build the seven images. The Dockerfiles are unmodified `FROM openjdk:12.0.2`.
cd Chapter16
source /usr/local/sdkman/bin/sdkman-init.sh
for s in product-service review-service recommendation-service product-composite-service; do
  ./gradlew :microservices:$s:build -x test
  ( cd microservices/$s && minikube image build -t hands-on/$s:v1 . )
done
for s in gateway authorization-server config-server; do
  ./gradlew :spring-cloud:$s:build -x test
  ( cd spring-cloud/$s && minikube image build -t hands-on/$s:v1 . )
done

# 2. THE BOOK'S MANIFESTS REFERENCE THE IMAGES UNTAGGED, WHICH MEANS :latest.
#    base/kustomization.yml has no `images:` tag transformer, so build :latest.
for n in product-service review-service recommendation-service product-composite-service \
         gateway authorization-server config-server; do
  minikube ssh -- "sudo ctr -n k8s.io images tag \
    docker.io/hands-on/$n:v1 docker.io/hands-on/$n:latest"
done
```
Expected all seven resolvable; actual: `minikube image ls` lists
`docker.io/hands-on/*:latest` for all seven. Tagging in containerd costs almost
no disk (`dm` unchanged) because the layers are already present: `:v1` is an
identical image with one extra reference.

```sh
# 3. create the Secret the manifests envFrom. The book expects you to supply it.
kubectl create secret generic config-client-credentials \
  --from-literal=CONFIG_SERVER_USR=dev-usr \
  --from-literal=CONFIG_SERVER_PWD=dev-pwd
```
The same pair used for ch12–14 (`Chapter12/.env`). Not in the book, not in the
repo — an operator-supplied input.

```sh
# 4. the manifests also mount a ConfigMap. NO SCRIPT SHIPS TO CREATE IT.
#    Build it from the chapter's own config-repo/ (its 7 yml files).
cd Chapter16
kubectl create configmap config-repo --from-file=config-repo/
kubectl create secret generic config-server-secrets \
  --from-literal=CONFIG_SERVER_USR=dev-usr --from-literal=CONFIG_SERVER_PWD=dev-pwd
```
Without this, `config-server` never leaves `ContainerCreating` with
`FailedMount ... configmap "config-repo" not found`, and every microservice then
loops in the config retry forever. This is the dependency the chapter does not
mention, and it is the one that stops the whole stack.

```sh
# 5. the manifest names the auth image differently from its build directory
minikube ssh -- "sudo ctr -n k8s.io images tag \
  docker.io/hands-on/authorization-server:latest docker.io/hands-on/auth-server:latest"
```

```sh
# 4. apply the dev overlay and watch the pods
kubectl apply -k kubernetes/services/overlays/dev
kubectl rollout restart deployment
kubectl get pods -o wide
```
Expected: 11 Services + 12 Deployments created, pods Running. Actual creation
succeeded (`service/*`, `deployment.apps/*` created for
auth-server, config-server, gateway, mongodb, mysql, product, product-composite,
rabbitmq, recommendation, review, zipkin-server) — with kustomize's only
complaint being that `bases:` is deprecated in favour of `resources:`.

## Problems encountered — each in the order hit, with its evidence

| What happened | Cause | Fix |
|---|---|---|
| `kubectl apply` succeeded; every pod `ErrImageNeverPull`, "not present with pull policy of Never" | I built with `eval $(minikube docker-env)` + `docker build`. That populates a docker store the kubelet never reads — containerd is where minikube v1.39 stores images. `minikube image ls` showed none of my seven while the docker store held **14 duplicate copies** | Build with `minikube image build`; delete the docker-store duplicates (recovered 1.6 G) |
| Pods still `ErrImageNeverPull` after `minikube image build` succeeded | I tagged `:v1`; `base/kustomization.yml` has **no `images:` tag transformer**, so the manifests reference images **untagged** → `:latest` | `minikube ssh -- sudo ctr -n k8s.io images tag ... :v1 ... :latest` — no rebuild, ~no disk |
| Pods then `CreateContainerConfigError`, `secret "config-client-credentials" not found` | manifests `envFrom: secretRef`; no Secret existed | `kubectl create secret generic config-client-credentials` with the ch12–14 pair |
| `auth-server` alone `ErrImageNeverPull` | the manifest says `image: hands-on/auth-server`, but the build directory is `spring-cloud/authorization-server` — **the book's directory name and manifest name differ** | `ctr images tag docker.io/hands-on/authorization-server:latest docker.io/hands-on/auth-server:latest` |
| `config-server` stuck `ContainerCreating`; event `FailedMount ... configmap "config-repo" not found` | the manifest mounts `config-repo-volume` from `configMap: config-repo`; no ConfigMap existed. **`kubernetes/` ships no script to create it** | `kubectl create configmap config-repo --from-file=<chapter>/config-repo/` — the chapter's own 7 yml files |
| `config-server` then `FailedMount` again, for `config-server-secrets` | the manifest also `envFrom` that Secret (it needs `CONFIG_SERVER_USR`/`PWD`) | `kubectl create secret generic config-server-secrets --from-literal=...` |
| 3–4 stale ReplicaSets per service; duplicate pods; crash loops | repeated `kubectl rollout restart` left old RS behind | `kubectl delete rs --all` + `kubectl delete pods --all`, one clean generation |

Two of these were my own faults of *reading*, and both are cheap but expensive:

- **A false negative I nearly acted on**: `ls -la /config-repo` inside the config-server
  pod showed files of "18–28 bytes", which I read as a truncated ConfigMap. The
  real values are intact (`product.yml` = 1314 bytes, `application.yml` = 1133).
  The number came from `awk '{print $9" "$5}'` printing the size of the `..data`
  **symlink**, not the target. The fix for this class is the one the skill already
  carries: verify with the data itself (`kubectl get configmap -o json`), never with
  a formatted listing.
- `minikube image build -q` fails outright — the command has **no `-q` flag**
  (only `--all`, `--build-env`, `-f`, `-n`, `--push`, `-t`). My first build used
  no `-q` and worked; the batch run added `-q` and all six failed silently.

## Where it stopped — a capacity limit, not a defect

Measured, not estimated:

```
before any build .............. 4.0 G avail (after removing Kafka/ZooKeeper images)
after image 1 of 7 ............ 3.7 G   (the openjdk:12.0.2 base, ~900 MB)
after image 7 of 7 ............ 2.5 G
after pulling mongo/rabbit/zip. 720 M
after the seven docker-store
  duplicates were deleted ..... 1.6 G
after the six rebuilt images .. 115 M   <- the floor of the remaining budget
after deleting gradle build
  dirs (jars already baked) .. 565 M
after removing nginx image
  and my own /tmp logs ....... 360 M
current ....................... 280 M avail, 100% used
```

Reclaiming bought ~180 MB and fixed the cluster's crash-looping, but the
filesystem is still full. With it at 100 % the containers cannot write their
writable layers, so `config-server` would not mount, `zipkin-server` was
OOMKilled, and `mysql`/`rabbitmq` restarted reporting `Error`.

After freeing that space, `config-server` reached `1/1 Running` and serves the
real config — but the seven microservices still never reach `Started`. Their own
logs show the boot banner, then `Fetching config from server at :
http://config-server:8888` repeating every ~4 s with **no error, no exception and
no `Connect Timeout Exception`** — unlike ch12–14, where the same loop printed the
exception. A `grep -inE 'error|exception|caused by|denied|bind|Started|Tomcat'`
over the whole log returns nothing. They are receiving a response but cannot
proceed, and their readiness probe (`/actuator/health` on port 80) gets
`connection refused` because no server ever binds.

The book's `product.yml` sets `server.port: 80` for the `docker` profile and
`server.port: 7001` by default, with `containerPort: 80` and
`targetPort: 80` in the manifest — so port 80 is the intended bind. Stopping here
rather than guessing at the remaining cause: the honest next probe is whether
port 80 can be bound at all in this container, or whether the config response is
being rejected by the client.

## What this leaves open for Chapters 17–20

All four remaining chapters add to the same cluster, so the same ceiling applies
and compounds:

| Chapter | Additional requirement | On the remaining budget |
|---|---|---|
| 17 | Ingress + `cert-manager` + Let's Encrypt | **Still requires a real public DNS name and a CA-issued certificate**, which a minikube in a codespace cannot obtain. Blocked independently of disk. |
| 18 | Istio sidecars, v1/v2 traffic routing | Istio's own images plus an injected sidecar per pod |
| 19 | EFK: Elasticsearch, Fluentd, Kibana | Elasticsearch alone is a multi-GB image and needs a JVM heap |
| 20 | Grafana dashboards | Small, but rides on 19 |

A named, reachable host (ch17's prerequisite), then ~3–5 GB more of image and
container storage, then several GB of RAM for Elasticsearch, are the actual
prerequisites. None of them can be produced inside this codespace.

## Benefit of the code run

The chapter's architectural change is real and visible in the source: with
`spring-cloud-starter-netflix-eureka-client` gone from the composite's
`build.gradle` and no `eureka` key anywhere under `config-repo`, the mechanism
for locator discovery has been removed, not merely disabled. Kubernetes' own DNS
and Services take over — the same property externalisation from ch12 and the same
tracing from ch14 still apply, and the credentials moved from a manifest into a
Secret. The reason it cannot be verified end to end here is capacity, not design.

## Business value & opportunities

1. **One less application dependency to operate.** Eureka — its image, its memory,
   its restart policy, its failure modes — disappears from the estate and is
   replaced by the platform's built-in Service discovery, which the operators are
   running already.
2. **Credentials move out of the artefacts.** `config-client-credentials` as a
   Secret means the config-server login is no longer in a manifest or a
   container image, and can be rotated without a rebuild.
3. **A promotion path through kustomize.** `base/` + `overlays/dev` + `overlays/prod`
   means dev and prod are the same manifests with an overlay, rather than two sets
   of YAML that drift — the same "one build promoted" property ch12 gave for
   configuration, now for the topology itself.

## Recommendations

- On minikube with the **containerd** runtime (v1.39+), build images with
  `minikube image build`. `eval $(minikube docker-env)` + `docker build` writes
  to a store the kubelet does not read, and the failure appears hours later as
  `ErrImageNeverPull` on every pod.
- Check what tag the manifests actually use before building. Untagged image
  references mean `:latest`; grep the manifests and the kustomization for an
  `images:` transformer, and if there is none, tag accordingly.
- Tag inside containerd with `minikube ssh -- sudo ctr -n k8s.io images tag ...`
  rather than re-building — identical image, one extra reference, ~no disk.
- Read `envFrom: secretRef` in the manifests as a list of what the operator must
  supply before anything starts.
- Budget the disk before a Kubernetes chapter. This one needed ~6 GB across the
  base image, seven services and four stateful dependencies on a 32 GB root
  filesystem that cannot grow.

## Still unverified (this chapter)

- **No end-to-end request.** The seven microservices never reach `Started`, so no
  aggregate was exercised and the book's `test-em-all.bash` was not run against
  the cluster. Every assertion in this report about the services is a *negative*
  observation, not a demonstration.
- **Kubernetes-native discovery is unproven.** The claim that Services replace
  Eureka rests on the source removal of Eureka, not on observed DNS resolution —
  the pods never bind a port, so no `product` → `review` interaction was seen.
- `overlays/prod` was never applied. Zipkin was never queried.
- The config-client retry loop has no diagnosed cause; the next probe is whether
  port 80 can be bound in this container.
- Chapter 17's prerequisite — a real public DNS name and a CA-issued certificate —
  cannot be satisfied by a minikube in a codespace, and is blocked independently
  of the disk ceiling documented above.
- Nothing from this chapter was committed until now; intermediate state lived only
  in the codespace and has now been captured to `Chapter16/evidence/`.

