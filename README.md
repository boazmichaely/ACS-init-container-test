# ACS Init Container Test

A ready-to-run demo of the four init-container "types" used to validate RHACS
**init container security coverage** (image scanning + Build/Deploy policy
evaluation of init containers): Clean, Dirty, Blue, and Red.

| Type | Meaning | Image | Config |
|---|---|---|---|
| **Clean** | No fixable Critical/Important CVEs, no policy violations | `gcr.io/distroless/base-debian12:debug-nonroot` | hardened (non-root, drop ALL caps, no priv-escalation) |
| **Dirty** | Has real CVEs, but well-behaved config | `gcr.io/distroless/python3-debian12:debug-nonroot` | same hardened config as Clean |
| **Blue** | Violates a policy doing what it's *supposed* to do (noise) | same clean image as above | `privileged: true`, mimics the common Elasticsearch/ECK `vm.max_map_count` sysctl-tuning init container pattern |
| **Red** | Violates a policy because it *misbehaves* (true positive) | `gcr.io/distroless/nodejs18-debian12:debug-nonroot` (real CVEs) | `privileged: true` with **no** legitimate justification |

All four types are built from public images plus plain Kubernetes YAML
(`securityContext`, image tag choice) - no custom image builds required.
Every image is a Google distroless variant: non-root by default, no package
manager at all (so no "package manager in image" findings for any of the
four), and Dirty/Red's language-runtime variants still carry real, fixable
Critical/Important CVEs in their bundled runtime and glibc. Each
`Deployment`'s `main` container is a `registry.k8s.io/pause:3.9` keep-alive
placeholder; it's not part of the story, just there so the pod has a running
main container alongside the init container being tested. The one
irreducible finding across all four apps is "90-Day Image Age" - `pause` is
rarely rebuilt, and distroless images omit build timestamps entirely for
reproducible builds (shows as a 1970/0001 date, which is expected, not a
bug).

## Deployment plan

Running `./scripts/setup.sh` creates, in a dedicated `acs-init-container-test`
namespace:

- **4 Deployments** (`clean-app`, `dirty-app`, `blue-app`, `red-app`), each
  with exactly one init container (the type under test, per the table above)
  and one `main` placeholder container.
- **`privileged` SCC** granted to the namespace's `default` service account -
  required for Blue/Red's `privileged: true` init container.
- **2 custom Build/Deploy policies**, scoped to this namespace only (see
  below).

## Policies

- **`EAP-Init-Test: Privileged Container (Blue/Red)`** - fires on any
  privileged container, main or init, in this namespace. Validates that
  Build/Deploy policy evaluation reaches init containers at all, and that it
  correctly attributes the violation to the specific init container by name.
- **`EAP-Init-Test: Fixable Important+ CVE (Dirty/Red)`** - fires on any
  container image, main or init, in this namespace with a fixable CVE at
  CVSS >= 7. Validates that image vulnerability scanning attributes CVE
  findings to init containers specifically, not just to the pod as a whole.

## Expected results

If init container security coverage is fully supported on the Central/Sensor
version under test:

- Central's Configuration Management `Container Type: INIT` filter returns
  all 4 deployments.
- `GET /v1/deployments/{id}` for any of the 4 apps lists both containers,
  with `"type": "INIT"` on the init container.
- Both custom policies fire, each attributed to the specific init container
  by name (e.g. `Container 'red-init' is privileged`):
  - `blue-app` and `red-app` trigger the Privileged Container policy.
  - `dirty-app` and `red-app` trigger the Fixable CVE policy.
  - `clean-app` and `blue-app` do **not** trigger the Fixable CVE policy -
    their init image has no fixable Critical/Important CVEs.
- Enabling `FAIL_DEPLOYMENT_CREATE_ENFORCEMENT` on the privileged-container
  policy and recreating the `red-app` pod blocks pod creation.

`roxctl image scan`/`roxctl image check` run directly against an image
(independent of any deployment) always returns accurate CVE data regardless
of the above - that path doesn't depend on deployment-level attribution.

If any deployment-level check above doesn't hold (filter returns 0, the
container list omits the init container, a policy doesn't fire, or
enforcement doesn't block), that specific capability isn't yet supported on
the Central/Sensor version under test. `./scripts/test.sh` walks through all
of these checks in order - see [`docs/TESTING.md`](docs/TESTING.md) for
exactly what each step does.

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

See [Deployment plan](#deployment-plan) below for exactly what `setup.sh`
creates. Once it's done, open Central and browse to the
`acs-init-container-test` namespace to explore the four deployments, their
images, and any violations directly in the UI.

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
