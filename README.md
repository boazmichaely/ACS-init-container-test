# ACS Init Container Test

A ready-to-run demo of the four init-container "types" used to validate RHACS
**init container security coverage** (image scanning + Build/Deploy policy
evaluation of init containers): Clean, Dirty, Blue, and Red.

| Type | Meaning | Image | Config |
|---|---|---|---|
| **Clean** | No fixable Critical/Important CVEs, no policy violations | `registry.access.redhat.com/ubi9/ubi-micro:latest` | hardened (non-root, drop ALL caps, no priv-escalation) |
| **Dirty** | Has real CVEs, but well-behaved config | `registry.access.redhat.com/ubi8/ubi-minimal:8.4` (EOL) | same hardened config as Clean |
| **Blue** | Violates a policy doing what it's *supposed* to do (noise) | same clean image as above | `privileged: true`, mimics the common Elasticsearch/ECK `vm.max_map_count` sysctl-tuning init container pattern |
| **Red** | Violates a policy because it *misbehaves* (true positive) | `docker.io/library/alpine:3.9` (EOL, real CVEs) | `privileged: true` with **no** legitimate justification |

All four types are built from public images plus plain Kubernetes YAML
(`securityContext`, image tag choice) - no custom image builds required. Each
`Deployment`'s `main` container is a `registry.k8s.io/pause:3.9` keep-alive
placeholder; it's not part of the story, just there so the pod has a running
main container alongside the init container being tested.

## What's in here

```
manifests/     Namespace + 4 Deployments (Clean/Dirty/Blue/Red init containers)
policies/      2 custom RHACS Build/Deploy policies scoped to the test namespace
scripts/       setup.sh, test.sh, cleanup.sh, acs_api.py, common.sh
docs/          Credential log (no secret values) + testing notes
.env.example   Config template - copy to .env (gitignored) or use env vars/prompts
```

## Prerequisites

- `oc` logged in to the target OpenShift cluster (`oc login ...`)
- `roxctl` (matching your Central's major version) on `PATH`
- `curl`, `python3` (no extra pip packages needed - stdlib only)
- An RHACS API token (Central -> Platform Configuration -> Integrations ->
  Authentication Tokens) with the `Admin` role, so the scripts can create and
  enable/disable enforcement on the demo policies.

## Setup

```bash
cp .env.example .env
# edit .env: set ROX_CENTRAL_ENDPOINT and ROX_API_TOKEN
./scripts/setup.sh
```

Anything missing from `.env`/the environment is prompted for interactively
(the token prompt is hidden input). **Nothing here reads a token from a
command-line argument**, so it never ends up in shell history or `ps` output.

`setup.sh` creates the `acs-init-container-test` namespace, grants the
`default` service account the `privileged` SCC (needed for the Blue/Red init
containers), applies the 4 Deployments, and creates two demo Build/Deploy
policies scoped to that namespace only: `EAP-Init-Test: Privileged Container
(Blue/Red)` and `EAP-Init-Test: Fixable Important+ CVE (Dirty/Red)`.

Open Central and browse to the `acs-init-container-test` namespace to explore
the four deployments, their images, and any violations directly in the UI.

## Testing (bonus)

```bash
./scripts/test.sh
```

Walks through the init-container test workflow using `roxctl` and the
Central REST API - Configuration Management filtering, image scanning,
policy evaluation, pipeline checks (`roxctl image check`), and admission
control - and saves a report to `results/report.md` (gitignored). See
[`docs/TESTING.md`](docs/TESTING.md) for what each step checks and how to
read the output.

## Cleanup

```bash
./scripts/cleanup.sh
```

Removes the namespace (and everything in it), the two custom policies, and
the SCC grant. This repo never modifies any default/out-of-the-box RHACS
policy - the two custom policies are clearly namespaced by name and by
`scope.namespace`.

## Secrets

No secret values are committed. See [`docs/CREDENTIALS.md`](docs/CREDENTIALS.md)
for a log of which tokens have been used against which Central instance and
their expiration dates. `.env` is gitignored from this repo's first commit.
