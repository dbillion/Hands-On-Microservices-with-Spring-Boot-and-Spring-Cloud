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

## Verdict: PARTIAL — reached four distinct blockers, three fixed; stopped by a
## hard capacity limit, not by the code

| Layer reached | State | Evidence |
|---|---|---|
| Cluster | Ready | minikube v1.37.0 on containerd, `kubectl get nodes` Ready |
| 7 Spring images | Built | all present in containerd's store |
| Tags | Fixed | `hands-on/*:latest` resolves in `minikube image ls` |
| Secret | Fixed | `config-client-credentials` created; pods advanced past `CreateContainerConfigError` |
| **Full stack running** | **NOT reached** | disk exhaustion |

Four services reached `Running` — `gateway`, `mongodb`, `mysql`, `rabbitmq` — and
`product`, `product-composite`, `recommendation` reached `Running` but not `Ready`
(still waiting on the config-server, which could not start). No end-to-end
request was completed, so no suite or aggregate assertion is recorded here.

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

## Problems encountered — four, all mine, in the order hit

| What happened | Cause | Fix |
|---|---|---|
| `kubectl apply` succeeded; every pod `ErrImageNeverPull`, "not present with pull policy of Never" | I built with `eval $(minikube docker-env)` + `docker build`. That populates a docker store the kubelet never reads — containerd is where minikube v1.39 stores images. `minikube image ls` showed none of my seven while the docker store held **14 duplicate copies** | Build with `minikube image build`, the containerd-native path; delete the docker-store duplicates (recovered 1.6 G) |
| Pods still `ErrImageNeverPull` after `minikube image build` succeeded and the image was visible in `minikube image ls` | I tagged `:v1`; the manifests reference the images **untagged**, which Kubernetes resolves to `:latest`. `base/kustomization.yml` has no `images:` transformer | `ctr -n k8s.io images tag ... :v1 ... :latest` inside minikube — near-zero disk cost, no rebuild |
| Pods then `CreateContainerConfigError`, `secret "config-client-credentials" not found` | The manifests use `envFrom: secretRef: config-client-credentials`; no Secret existed | `kubectl create secret generic config-client-credentials` with the ch12–14 credential pair |
| `gateway mongodb mysql rabbitmq` Running but `config-server` stuck `ContainerCreating`, `zipkin-server` **OOMKilled**, `mysql`/`rabbitmq` restarting in `Error` | **Disk exhaustion.** The root filesystem is a fixed 32 GB overlay with no growth possible; between the cluster, seven ~215 MB service images, the shared `openjdk:12.0.2` base (~900 MB), mysql/mongo/rabbitmq/zipkin pulls and the minikube node, it reached 100 % | Not fixed — see §Where it stopped |

A fifth, non-fatal: `minikube image build -q` fails outright — the command has
**no `-q` flag** (only `--all`, `--build-env`, `-f`, `-n`, `--push`, `-t`). My
first build used no `-q` and worked; the batch run added `-q` and all six failed
silently.

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
final ......................... 161 M avail, 100% used
```

With the filesystem full, the containers can no longer write their writable layers
or logs: `zipkin-server` is `OOMKilled`, `mysql` and `rabbitmq` restart reporting
`Error`, and `config-server` never leaves `ContainerCreating`.

Chapter 16 therefore reaches **"images resolve, Secret resolves, four pods
Running"** and stops at **disk**. There is no configuration or code fault to
record; the environment cannot hold the chapter's whole topology at once.

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

- No end-to-end request: `config-server` never became Ready, so the four
  microservices never left `Running`→`Ready` and no aggregate was exercised.
- Kubernetes-native discovery (client-side vs server-side, Service DNS resolution
  between the microservices) is unverified — the claim rests on the source
  removal of Eureka, not on observed DNS lookups.
- `overlays/prod` was never applied.
- Zipkin was never queried.
- Nothing from this chapter was committed; the state was left on the codespace.

