# pi-ai provider sign-in (OAuth / device code)

Signs in to a pi-ai catalog provider through the harness authorization seam and
stores the credential in the real DSH home (`~/.dsh/.credentials.yaml`,
self-refreshing), so every `dsh` profile — headless, web, SDK — authenticates
with it. No shipped profile mounts the authorization service yet, so this tool
boots its own minimal composition (`cordis.yml`).

```sh
node login.mjs                 # sign in to github-copilot (OAuth device code)
node login.mjs openai-codex    # any other registered flow
node verify.mjs gpt-5-mini     # stream one real request through the stored grant
```

`login.mjs` prints a github.com/login/device URL and a code; approve in the
browser and the grant lands in the credential store. Routes still need
declaring in `~/.dsh/settings.yaml` under `llm-pi-ai: providers:` — a catalog
provider like `github-copilot` needs only `github-copilot: {}`.

## Known limitation

Copilot grants carry `availableModelIds`; pi-ai filters the catalog to them,
so a model id present in the catalog but absent from the grant fails at
request time with `model_not_supported`. Check the grant's list before
picking a default model.
