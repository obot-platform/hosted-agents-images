#!/usr/bin/env bash
# Serves an ADK chatbot over HTTP for Obot's port option.
#
# The port comes from the config rather than being hard-coded: the agent
# definition declares it, and Obot publishes /agent-connect/{instance id} in
# front of it. The agent module reads the same config for its model and tools.

set -euo pipefail
# shellcheck source=../lib/obot-agent.sh
source /usr/local/lib/obot-agent.sh

obot::require_config

port="$(obot::listen_port)"
[ -n "$port" ] || obot::fail "this agent declares no port; it cannot serve a chat UI"

# Without explicit URIs, ADK stores sessions and artifacts beside the agent
# package inside the image, so every conversation is lost when the sandbox
# restarts. Both are pointed at the pool volume instead.
state="$(obot::state_dir)"
mkdir -p "$state/artifacts"

# The agent code. A harness is a runtime, not an agent: the template says which
# agent to run by pointing at a repository, and that repository's root is the
# agents directory ADK loads.
#
# The image deliberately bundles no agent. It did once, as a fallback, and the
# two copies drifted the moment the configuration format changed -- the copy
# nobody was running silently kept working while the real one broke.
[ -n "$(obot::config '.source.url // empty')" ] ||
  obot::fail "this agent has no gitRepo. The ADK harness runs the agent in the repository its template points at; set one on the template."

agents_dir="$(obot::clone_source)"
obot::log "loading agents from $agents_dir"

# Decline ADK's telemetry on the agent's behalf. The UI asks the first time it
# is opened and remembers the answer in ~/.adk/config.json; nobody is in a
# position to answer for a hosted sandbox, and a consent dialog is not what a
# user opening their agent is there for. An explicit false, not merely an
# absent file, since absent is what makes it ask.
mkdir -p "$HOME/.adk"
if [ ! -s "$HOME/.adk/config.json" ]; then
  printf '{"telemetry": false}\n' >"$HOME/.adk/config.json"
fi

cd /app

# Load the agent before serving it. `adk web` imports an agent only when a
# message arrives, so a module that cannot import -- a missing dependency, a
# model the agent cannot use -- leaves the sandbox reporting itself ready and
# failing on the first thing a user does. Failing here surfaces it on the
# instance instead.
if ! (cd "$(dirname "$agents_dir")" && python -c "
import importlib, pathlib, sys
root = pathlib.Path('$agents_dir')
sys.path.insert(0, str(root))
names = [p.name for p in root.iterdir() if (p / '__init__.py').exists()]
if not names:
    raise SystemExit(f'no agent package found in {root}')
for name in names:
    importlib.import_module(name)
print('loaded:', ', '.join(names))
") 2>/tmp/import-error; then
  obot::log "the agent failed to load:"
  sed "s/^/[obot]   /" /tmp/import-error >&2
  exit 1
fi

# The UI is a single-page app: it builds its API calls at load time, so without
# the prefix it calls Obot's root instead of its own and reports that it cannot
# find any agents.
prefix="$(obot::public_path)"

obot::log "serving the chat UI on port $port${prefix:+ under $prefix}"

# An array rather than an interpolated string: the prefix is optional, and
# building the argument list by hand would leave the quoting to word splitting.
args=(--host 0.0.0.0 --port "$port")
[ -n "$prefix" ] && args+=(--url_prefix "$prefix")
args+=(
  --session_service_uri "sqlite:///$state/sessions.db"
  --artifact_service_uri "file://$state/artifacts"
  "$agents_dir"
)

exec adk web "${args[@]}"
