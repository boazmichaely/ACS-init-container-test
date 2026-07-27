# ACS Init Container Test

**Repo:** https://github.com/boazmichaely/ACS-init-container-test

Kubernetes init containers run and finish before an app's main container
starts - config pulls, migrations, permission fixes, sysctl tuning. RHACS is
adding the ability to scan and enforce policy on init containers, not just
main containers. This repo checks that it actually works: does image
scanning find CVEs inside an init container? Does a policy fire because of
something an init container does? Can admission control block a bad
deployment because of its init container, before it ever starts?

Four tiny demo apps answer those questions, one at a time.

| App | Init container has fixable CVEs? | Init container is privileged? | What it proves |
|---|---|---|---|
| `clean-app` | No | No | Baseline - a well-behaved init container should raise zero findings. |
| `dirty-app` | Yes | No | Image scanning finds CVEs inside the init container and attributes them to it, not just the pod. |
| `blue-app` | No | Yes | Policy evaluation catches a privileged init container even when it's a legitimate, common pattern (e.g. the sysctl tuning many Elasticsearch deployments run). |
| `red-app` | Yes | Yes | Same as `blue-app`, but with no legitimate excuse - and admission control can actually block it. |

All four are plain public images plus Kubernetes YAML - no custom image
builds.

## Deployment plan

Running `./scripts/setup.sh` creates, in a dedicated `acs-init-container-test`
namespace:

- **4 Deployments** (`clean-app`, `dirty-app`, `blue-app`, `red-app`), each
  with one init container (per the table above) and one `main` placeholder
  container.
- **`privileged` SCC** granted to the namespace's `default` service account -
  required for `blue-app`/`red-app`'s privileged init container.
- **2 custom Build/Deploy policies**, scoped to this namespace only (see
  below).

## Policies

- **`EAP-Init-Test: Privileged Container (Blue/Red)`** - fires on any
  privileged container, main or init, in this namespace. Validates that
  Build/Deploy policy evaluation reaches init containers, and attributes the
  violation to the specific init container by name.
- **`EAP-Init-Test: Fixable Important+ CVE (Dirty/Red)`** - fires on any
  container image, main or init, in this namespace with a fixable CVE at
  CVSS >= 7. Validates that vulnerability scanning attributes CVE findings
  to init containers specifically.

## Expected results

If init container coverage is fully working on the Central/Sensor version
under test:

- Central's Configuration Management `Container Type: INIT` filter returns
  all 4 deployments.
- `GET /v1/deployments/{id}` for any of the 4 apps lists both containers,
  with `"type": "INIT"` on the init container.
- Both custom policies fire, each attributed to the specific init container
  by name (e.g. `Container 'red-init' is privileged`), matching the table
  above (`blue-app`/`red-app` trigger the privileged-container policy;
  `dirty-app`/`red-app` trigger the CVE policy).
- With enforcement enabled on the privileged-container policy, deleting
  `red-app` and re-applying its manifest gets the `oc apply` itself rejected
  by the admission webhook - the same experience a user would get trying to
  deploy a non-compliant workload for the first time.

If any check above doesn't hold, that capability isn't yet supported on the
Central/Sensor version under test. (You'll also see a `90-Day Image Age`
finding on every app - that's just the base/placeholder images being old,
unrelated to init containers.)

## What's in here

```
manifests/     Namespace + 4 Deployments (Clean/Dirty/Blue/Red init containers)
policies/      2 custom RHACS Build/Deploy policies scoped to the test namespace
scripts/       setup.sh, test.sh, cleanup.sh, acs_api.py, common.sh
.env.example   Config template - copy to .env (gitignored) or use env vars/prompts
```

## Prerequisites

- `oc` logged in to the target OpenShift cluster (`oc login ...`)
- `roxctl` (matching your Central's major version) on `PATH`
- `curl`, `python3` (no extra pip packages needed - stdlib only)
- An RHACS API token (Central -> Platform Configuration -> Integrations ->
  Authentication Tokens) with the `Admin` role, so the scripts can create and
  enable/disable enforcement on the demo policies. Revoke it once you're done.

## Setup

```bash
cp .env.example .env
# edit .env: set ROX_CENTRAL_ENDPOINT and ROX_API_TOKEN
./scripts/setup.sh
```

Anything missing from `.env`/the environment is prompted for interactively
(the token prompt is hidden input). Nothing here reads a token from a
command-line argument, so it never ends up in shell history or `ps` output.
No secret values, hostnames, or token identifiers are committed - `.env` is
gitignored.

See [Deployment plan](#deployment-plan) above for exactly what `setup.sh`
creates. Once it's done, open Central and browse to the
`acs-init-container-test` namespace to explore the four deployments, their
images, and any violations directly in the UI.

## Testing (bonus)

```bash
./scripts/test.sh
```

Runs three checks against the deployments `setup.sh` created, using `roxctl`
and the Central REST API. Saves a full report to `results/report.md`
(gitignored). It's read-only except for a short window in step 3, where it
toggles enforcement on one custom policy and turns it back off before
exiting.

1. **Configuration Management.** Queries `/v1/deployments` with a
   `Container Type: INIT` filter and confirms all 4 apps match. Also fetches
   `blue-app`'s full container list to show both its `main` and `blue-init`
   containers, with `blue-init` correctly typed as `INIT`.
2. **Policy behavior.** Queries `/v1/alerts` for the namespace and checks
   that the `Privileged Container` policy fired on `blue-app` and `red-app`.
   Also runs `roxctl deployment check` against `manifests/04-red.yaml` to
   show the same violations from the CLI side.
3. **Admission control.** Enables enforcement on the privileged-container
   policy, deletes the `red-app` Deployment, then re-applies its manifest
   and checks whether `oc apply` itself gets rejected by the admission
   webhook. Enforcement is turned back off afterward, and `red-app` is
   restored if the redeploy was blocked.

## Cleanup

```bash
./scripts/cleanup.sh
```

Removes the namespace (and everything in it), the two custom policies, and
the SCC grant. This repo never modifies any default/out-of-the-box RHACS
policy - the two custom policies are clearly namespaced by name and by
`scope.namespace`.
