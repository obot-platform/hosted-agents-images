# Hosted agent images

The agent runtimes that ship with Obot. Each is a *harness*: the image an agent
template runs in. The templates themselves live in
[hosted-agents-catalog](https://github.com/obot-platform/hosted-agents-catalog).

Images are published to `ghcr.io/obot-platform/hosted-agents-images/<name>`,
built for `linux/amd64` and `linux/arm64`, and signed with cosign. All three
build on Chainguard wolfi (glibc, continuously rebuilt CVE-free), pinned by
digest and kept current by dependabot. A push to
`main` publishes `:main`; a `v*` tag publishes that tag and moves `:latest`
unless the tag is a release candidate.

| Directory | Harness | Interface |
|---|---|---|
| `Dockerfile.claude-code` | Claude Code CLI | terminal |
| `Dockerfile.codex` | OpenAI Codex CLI | terminal |
| `Dockerfile.adk` | Google Agent Development Kit | HTTP chat UI on a port |

Build from the repository root, because each Dockerfile also copies the shared
library:

```sh
docker build -f Dockerfile.claude-code -t hosted-agent-claude-code:dev .
```

## The contract an image is started with

Obot supplies three things, and `lib/obot-agent.sh` is the shared reader for
them. An image that follows this contract needs no Obot-specific code beyond
translating it into whatever its own tool expects.

| Where | Mode | What |
|---|---|---|
| `/etc/obot/agent.json` | `0444` | Everything the agent is configured with: complete MCP URLs, model endpoints with their wire protocol, skill directories, the repository to check out, and the answers the user gave. No credentials. |
| `/etc/obot/secrets.json` | `0440` | The credentials for those endpoints: MCP servers by ID, models by *provider*, since every model from one provider shares an endpoint. |
| `/etc/obot/skills/<name>/` | `0444` | Each skill's files, already written. |
| `/etc/obot/credential` | `0440` | The agent's own API key, for anything the config does not describe. |

Every endpoint in the config is an **absolute URL**. An image joins nothing
together and needs no knowledge of Obot's address or routes for anything the
config describes:

```json
{"mcpServers": [{"id": "ms1github",
                 "url": "https://obot.example.com/mcp-connect/ms1github",
                 "transport": "streamable-http"}],
 "models":     [{"id": "m1sonnet", "model": "claude-sonnet-4-5",
                 "api": "anthropic",
                 "baseURL": "https://obot.example.com/api/llm-proxy/anthropic",
                 "default": true}]}
```

`api` is what an image dispatches on: an Anthropic-native client and an
OpenAI-compatible one are different clients, and nothing in a URL says which is
which. `obot::model anthropic` returns the model, base URL and key for that
protocol, or nothing if the agent has no such model.

**`baseURL` carries no API version**, because the version belongs to the
protocol a client speaks rather than to the routing. An Anthropic client appends
`/v1/messages` to it; an OpenAI one treats `/v1` as part of its base and appends
`/responses`. Naming a version in the config would pick one of those conventions
for every image, and could not express a provider moving to `/v2`. So an image
composes the path its own client expects -- `codex` adds `/v1`, `claude-code`
uses the value as it is.

**Every model the agent may use is listed**, not just one. A template granting
`"*"` yields the installation's whole catalogue; a template naming an alias or
specific models yields those. Exactly one carries `"default": true` — whatever
`obot://llm` points at, or the first listed if no alias is bound — so an image
that wants a single model always has an answer. It is a hint, not a
restriction: the agent is authorized for every model in the list.

**Calling Obot directly.** For the rest — anything the config does not describe
— `obotURL` is Obot's own address and `/etc/obot/credential` is the key to use
against it, read with `obot::obot_url`. This is *not* the host in `publicURL`:
that is the address a browser reaches the agent on, and is commonly not routable
from inside the cluster. Answering "where is Obot" with the browser's answer is
what leaves a sandbox unable to reach its own models. An image that only uses
the MCP servers, models and skills it was given never needs this.

**Why two files.** The configuration is world-readable so it can be inspected,
logged or copied freely; only the credentials are protected. The secrets file is
group-readable rather than owner-only because Kubernetes owns secret files
`root:fsGroup` and nothing here runs as root -- `0400` would leave the agent
unable to read its own credential. `obot::require_config` merges the two into a
private file, so nothing downstream has to know there were ever two.

The agent never holds a provider key: Obot holds it, proxies the request, and
attributes usage to the instance.

## What survives a restart

A sandbox's container filesystem is rebuilt from the image whenever the pod is
recreated. Only the pool volume, mounted at `$workspace`, persists — so anything
worth keeping is relocated there and symlinked back:

| Persisted at | For |
|---|---|
| `$workspace/.obot/state/.claude`, `.claude.json` | Claude Code's history, projects and settings |
| `$workspace/.obot/state/.codex` | Codex's sessions and history |
| `$workspace/.obot/state/sessions.db`, `artifacts/` | ADK conversations and artifacts |
| `$workspace/<repo>` | The checkout, including uncommitted work |

**A restart refreshes configuration but never touches work.** Every boot rewrites
the MCP config, the model endpoint and the skill links from the two config
files, so an administrator's change takes effect on the next restart. The
checkout is left exactly as it is: it holds the agent's uncommitted work, and
re-cloning or force-checking-out would discard it. If the configured ref no
longer matches the checked-out branch, that is logged rather than acted on.

State directories are created group-writable and setgid (`2775`). The volume is
owned by the pod's fsGroup rather than by any one user, so an image that later
runs as a different uid — a rebuild on a new base image — still reaches its own
state.

## Notes and current limits

* **Interactive harnesses.** `claude-code` and `codex` are shell applications
  and exit immediately without a TTY, so their harness sets `interactive: true`.
  That is also what makes the terminal option work: a console can only be
  attached to a container that was started with one.
* **Branch checkout.** A ref that names a branch is checked out *as* a branch
  with an upstream, not as a detached HEAD, so an agent that commits can push.
  A tag or commit SHA necessarily detaches.
* **Skills arrive as files.** Obot fetches each skill from the repository it was
  indexed from and writes it to `/etc/obot/skills/<name>/`; the entrypoints only
  link that into wherever the tool discovers skills. Skill content is capped
  (256KiB per file, 512KiB per skill) because it travels in a Kubernetes Secret,
  which is limited to 1MiB in total.
* **The ADK UI is ADK's dev UI.** `adk web` is what the Agent Development Kit
  ships; it is a capable chat interface but is not branded as a product surface.
* **The chatbot speaks both protocols.** It runs on whichever model Obot marked
  default, Anthropic or OpenAI, through LiteLLM. Accepting only OpenAI was what
  previously left an Anthropic-configured agent with no usable model.
* **`git clone` uses no credential**, so a private repository fails. Obot holds
  git credentials for skill repositories but they are not yet offered to an
  agent's own repository.

## Versioning and releasing

Each image is tagged with the version of the tool it packages, declared in
[`images.yaml`](images.yaml) -- `claude-code:2.1.220`, `codex:0.146.0`,
`adk:2.6.1`. There is no repo-wide release tag: one package moving publishes one
image, and the others are untouched.

`images.yaml` is the only place a version lives. The Dockerfiles read it as a
build argument, so the pin and the published tag cannot disagree. To rebuild the
same upstream version -- an entrypoint change, a base-image bump -- set
`packaging: N` on that image; the tag becomes `version-N`, which is what lets it
publish when the upstream version has not moved.

Claude Code and Codex are installed from their official releases -- the native
binary and the released musl binary respectively, not npm -- so the pinned
version is baked in and a sandbox starts offline. Node 24 and Python 3.12 are
present on every image as general tooling agents shell out to.

A daily job (`check-upstream.yml`) compares each package against its registry
and opens a pull request raising the version when a newer release appears.
Merging it, or any change that moves a tag, builds and signs that image, scans
it, and asks the catalog to open a pull request pointing its harness at the new
tag. Dependabot keeps the base-image digests, the secondary Python pins and the
workflow actions current.
