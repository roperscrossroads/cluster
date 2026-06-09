# hermes-peer

Hermes as an **A2A mesh peer** — a serving Deployment (not the OpenShell sandbox).
One pod, two containers sharing `localhost`:

- **hermes** — `hermes gateway` with the api_server platform on `127.0.0.1:8642`
  (enabled by `API_SERVER_KEY`); reaches the LLM via the LiteLLM proxy
  (`litellm.home.arpa`, `local` group, vkey `agno-hermes`).
- **a2a-shim** — fronts hermes' `/v1/chat/completions` as an A2A peer on `:9400`
  (the `Service` port). Image built from `~/agents/a2a-shim`.

The Agno infrastructure team consumes it over the envoy-internal HTTPRoute
(`hermes-peer-int.${SECRET_DOMAIN}`). Design + rationale (why a Deployment, not the
sandbox): `~/agents/docs/specs/2026-06-08-hermes-a2a-mesh-peer-design.md`. Beads:
`agents-oqy.3` (this) → `agents-oqy.4` (agno wiring).

## Gated steps before the first reconcile

All are real-infra mutations — run with operator go-ahead, smoke-test each:

1. **Build + push the a2a-shim image** (Forgejo Actions or local buildx) to the
   internal Zot registry as `registry.home.arpa:8080/a2a-shim:v0.1.0`
   (`~/agents/a2a-shim/Dockerfile`).
2. **Mint the LiteLLM vkey** `agno-hermes` (allowlist `local`) via
   `~/infra-new services/litellm-provision-keys.yml`.
3. **Create the Secret**:
   ```sh
   API_SERVER_KEY=$(openssl rand -hex 32)
   # LITELLM_VKEY = the minted agno-hermes vkey value
   # write app/secrets/hermes-peer-secret.sops.yaml from the .example, then:
   sops --encrypt --in-place app/secrets/hermes-peer-secret.sops.yaml
   ```
   Then uncomment `./secrets/hermes-peer-secret.sops.yaml` in `app/kustomization.yaml`.
4. **Push** → Flux reconciles. Verify the pod is Ready and both containers healthy.

## Smoke / open verification items

- **hermes `provider: custom` + LiteLLM**: confirm the gateway's api_server routes
  `/v1/chat/completions` to the `local` model via `OPENAI_BASE_URL=litellm.home.arpa/v1`
  + `OPENAI_API_KEY=<vkey>` (the sandbox used `inference.local`; this is the first
  test of the direct-LiteLLM path). `SSL_CERT_FILE`/`REQUESTS_CA_BUNDLE` point at the
  mounted internal CA so httpx trusts `*.home.arpa`.
- **shim reaches hermes**: `curl localhost:9400/.well-known/agent-card.json` and an
  A2A `message/send` inside the pod → grounded reply.
- **cross-box**: from agno-compute, `curl https://hermes-peer-int.${SECRET_DOMAIN}/...`.

## Hardening TODO (follow-up bead)

- **NetworkPolicy / CiliumNetworkPolicy** restricting egress to LiteLLM + DNS only
  (omitted in v1 to match notes-verifier's posture and avoid shipping a too-strict
  policy that breaks egress; the design doc calls for it). Hermes' `terminal:
  backend: local` runs tool commands in-container — keep the pod non-root + no
  estate write credentials when hardened.
