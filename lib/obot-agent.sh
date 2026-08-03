#!/usr/bin/env bash
# Shared setup for Obot hosted agent images.
#
# Obot hands a sandbox two files. Every endpoint in them is an absolute URL and
# every skill is already on disk, so an image reads them and boots: nothing here
# knows Obot's address, its routes, or that it is Obot at all, which is what
# keeps these images from breaking when any of that changes.
#
#   /etc/obot/agent.json    world-readable, carries no secret
#   /etc/obot/secrets.json  readable only by the agent, credentials keyed by ID
#
# They are split so the configuration can be read, logged or copied freely while
# only the credentials are protected. obot::require_config merges them once into
# a private file, and every helper below reads the merged view -- so nothing
# downstream has to know there were ever two.
#
# The shape (see pkg/controller/handlers/hostedagent/config.go):
#
#   {"version":"v1",
#    "instance":{"id":…,"userID":…,"name":…},
#    "secretsFile":"/etc/obot/secrets.json",
#    "workspace":"/workspace",
#    "source":{"url":…,"ref":…,"subdir":…},
#    "listenPort":8000,
#    "publicPath":"/agent-connect/<instance id>", "publicURL":"https://…/agent-connect/<id>",
#    "mcpServers":[{"id":…,"name":…,"url":…,"transport":…,"headers":{…}}],
#    "models":[{"id":…,"model":…,"apis":["anthropic"|"openai-responses"|"openai-chat-completions"],
#                "provider":…,"baseURL":…,"apiKey":…,"default":true}],
#    "skills":[{"id":…,"name":…,"path":"/etc/obot/skills/<name>","description":…}],
#    "answers":{…}}

set -euo pipefail

OBOT_CONFIG_FILE="${OBOT_CONFIG_FILE:-/etc/obot/agent.json}"

obot::log() { printf '[obot] %s\n' "$*" >&2; }
obot::fail() { printf '[obot] error: %s\n' "$*" >&2; exit 1; }

# obot::require_config merges the two files into one private document.
#
# The merge is by ID, so a credential lands on the endpoint it belongs to. The
# result goes to a file only this user can read, since it now holds secrets --
# and to a file rather than a variable because the whole point of the split is
# that credentials do not sit in an environment every subprocess inherits.
obot::require_config() {
  [ -r "$OBOT_CONFIG_FILE" ] ||
    obot::fail "no configuration at $OBOT_CONFIG_FILE; this image must run as an Obot hosted agent"

  local secrets_file merged_dir
  secrets_file="$(jq -r '.secretsFile // empty' <"$OBOT_CONFIG_FILE")"

  merged_dir="$(mktemp -d)"
  chmod 700 "$merged_dir"
  OBOT_MERGED_CONFIG="$merged_dir/agent.json"

  if [ -n "$secrets_file" ] && [ -r "$secrets_file" ]; then
    jq -s '
      .[0] as $config | .[1] as $secrets
      | $config
      | .mcpServers = [ .mcpServers[]? | . + {headers: ((.headers // {}) + (($secrets.mcpServers[.id].headers) // {}))} ]
      | .models = [ .models[]? | . + {apiKey: (($secrets.modelProviders[.provider].apiKey) // null)} ]
    ' "$OBOT_CONFIG_FILE" "$secrets_file" >"$OBOT_MERGED_CONFIG"
  else
    # No secrets file: unauthenticated endpoints are unusual but not this
    # script's business to reject, and the error is clearer from the tool that
    # actually tries to connect.
    [ -n "$secrets_file" ] && obot::log "no readable secrets at $secrets_file; endpoints will be unauthenticated"
    cp "$OBOT_CONFIG_FILE" "$OBOT_MERGED_CONFIG"
  fi

  chmod 600 "$OBOT_MERGED_CONFIG"
  OBOT_CONFIG_FILE="$OBOT_MERGED_CONFIG"
  export OBOT_CONFIG_FILE
}

# obot::config runs a jq filter over the configuration. Extra arguments are
# passed to jq, so a caller can bind values with --arg rather than interpolating
# them into the filter.
obot::config() {
  local filter="$1"
  shift
  jq -r "$@" "$filter" <"$OBOT_CONFIG_FILE"
}

obot::workspace() { obot::config '.workspace // "/workspace"'; }
obot::listen_port() { obot::config '.listenPort // empty'; }

# obot::public_path is the path prefix the agent is published under, empty when
# it serves nothing. A server that ignores it builds links against its own root,
# which is not where anyone reaches it.
obot::public_path() { obot::config '.publicPath // empty'; }
obot::public_url() { obot::config '.publicURL // empty'; }
# shellcheck disable=SC2016  # $k is a jq variable, bound below with --arg.
obot::answer() { obot::config '.answers[$k] // empty' --arg k "$1"; }

# obot::model selects the model to use, as "model<TAB>baseURL<TAB>apiKey".
#
# "$1" is the wire protocol the caller speaks: "anthropic", "openai-responses"
# or "openai-chat-completions". These are request formats rather than vendors,
# and a client written for one cannot talk to another. A model lists every
# protocol it accepts -- usually more than one -- so this asks whether the model
# accepts what the caller speaks, not what it prefers.
#
# The model marked default is preferred, otherwise the first that fits. Emits
# nothing when the agent has no model the caller can talk to.
obot::model() {
  # shellcheck disable=SC2016  # $api is a jq variable, bound below with --arg.
  obot::config '
    [.models[]? | select((.apis // []) | index($api))] as $candidates
    | (($candidates | map(select(.default)) | first) // ($candidates | first))
    | if . == null then empty else [.model, .baseURL, .apiKey] | @tsv end
  ' --arg api "$1"
}

# obot::has_model reports whether any model of the given protocol is configured.
obot::has_model() {
  [ -n "$(obot::model "$1")" ]
}

# obot::state_dir is where an agent's own state belongs: on the pool volume,
# which is the only thing in a sandbox that survives a restart. Everything else
# -- the home directory, the image filesystem -- is rebuilt from the image every
# time the deployment rolls, so state left there is silently lost.
obot::state_dir() {
  local dir
  dir="$(obot::workspace)/.obot/state"
  mkdir -p "$dir"
  # Group-writable and setgid, because the volume is owned by the pod's fsGroup
  # rather than by any particular user. A default 0755 belongs to whichever uid
  # happened to create it first, so an image that later runs as a different user
  # -- a rebuild on a new base, say -- would be locked out of its own state.
  # Failure is ignored: on a later boot the directory belongs to someone else
  # and is already correct.
  chmod 2775 "$(obot::workspace)/.obot" "$dir" 2>/dev/null || true
  printf '%s' "$dir"
}

# obot::persist moves a path onto the pool volume and leaves a symlink behind,
# so a tool that insists on writing to a fixed location still keeps its state.
#
# "$2" is "dir" or "file", which decides what to create when the tool has not
# written anything yet. On later boots the path is already a symlink and this
# does nothing.
obot::persist() {
  local target="$1" kind="${2:-dir}" state dest
  state="$(obot::state_dir)"
  dest="$state/$(basename "$target")"

  # Already linked by an earlier boot. The link is only good if what it points
  # at is still there: a pool volume can be replaced, or the link can outlive
  # the state it was made for, and a directory symlink left dangling fails every
  # write through it with a bare "Permission denied" that names the link rather
  # than the missing target. Recreating the directory is safe -- there is no
  # content to lose, since the thing it pointed at is gone.
  if [ -L "$target" ]; then
    if [ ! -e "$target" ] && [ "$kind" = dir ]; then
      obot::log "$target points at missing state; recreating $dest"
      mkdir -p "$dest"
    fi
    return 0
  fi

  if [ ! -e "$dest" ]; then
    if [ -e "$target" ]; then
      # First boot with content already in the image: keep it rather than
      # discarding whatever the image shipped.
      mv "$target" "$dest"
    elif [ "$kind" = dir ]; then
      mkdir -p "$dest"
    fi
    # A file the tool has not written yet is deliberately not created. An empty
    # file is not an empty document -- a tool reading its own config back finds
    # zero bytes where it expects JSON and reports corruption. Writing through
    # the dangling symlink below creates it with the tool's own first content.
  elif [ -e "$target" ]; then
    # The persisted copy wins: it is the one with the history in it.
    rm -rf "$target"
  fi

  mkdir -p "$(dirname "$target")"
  ln -sfn "$dest" "$target"
}

# obot::clone_source checks out the repository the agent or user chose and
# echoes the directory to work in. Without one, the workspace itself is used.
obot::clone_source() {
  local url ref subdir workspace
  workspace="$(obot::workspace)"
  url="$(obot::config '.source.url // empty')"
  if [ -z "$url" ]; then
    printf '%s' "$workspace"
    return 0
  fi
  ref="$(obot::config '.source.ref // empty')"
  subdir="$(obot::config '.source.subdir // empty')"

  local name dir
  name="$(basename "${url%.git}")"
  dir="$workspace/$name"

  # A restart must not touch an existing checkout: the agent's uncommitted work
  # lives there, and re-cloning or force-checking-out would discard it. The
  # rest of the configuration is rebuilt on every boot, but this is the one
  # thing that is the user's, not Obot's.
  if [ -d "$dir/.git" ]; then
    local current
    current="$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
    if [ -n "$ref" ] && [ "$current" != "$ref" ]; then
      # Say so rather than switching: the checkout may have work on it, and a
      # silent divergence from the configured ref is worse than a noisy one.
      obot::log "note: $dir is on '$current' but the agent is configured for '$ref'; leaving it alone"
    else
      obot::log "repository already present at $dir; leaving it as it is"
    fi
    printf '%s' "$dir${subdir:+/$subdir}"
    return 0
  fi

  obot::log "cloning $url${ref:+ at $ref}"
  if [ -n "$ref" ]; then
    # A full clone rather than `clone --branch`: --branch accepts only branches
    # and tags, and a ref may equally be a commit SHA.
    git clone --quiet -- "$url" "$dir"

    # A branch is checked out as a branch, not as a detached HEAD. These agents
    # commit and push, and work done on a detached HEAD belongs to no branch.
    if git -C "$dir" rev-parse --verify --quiet "refs/remotes/origin/$ref^{commit}" >/dev/null; then
      git -C "$dir" checkout --quiet -B "$ref" --track "origin/$ref"
    elif sha="$(git -C "$dir" rev-parse --verify --quiet "$ref^{commit}")"; then
      # A tag or a commit. There is no branch to be on, so detaching is correct;
      # resolving to the SHA first keeps a ref that looks like a path from being
      # read as one.
      git -C "$dir" -c advice.detachedHead=false checkout --quiet --detach "$sha"
    else
      obot::fail "could not resolve '$ref' in $url"
    fi
  else
    git clone --quiet --depth 1 -- "$url" "$dir"
  fi

  printf '%s' "$dir${subdir:+/$subdir}"
}

# obot::link_skills links each skill Obot placed on disk into a directory the
# agent's own tooling discovers. Obot has already written the files; this only
# puts them where the tool looks.
obot::link_skills() {
  local target="$1" count=0 path name link

  mkdir -p "$target"

  # The link directory may live on the pool volume and outlive this boot, so a
  # skill the agent no longer has would otherwise stay linked to a path that is
  # no longer mounted. Dangling links are cleared before relinking.
  for link in "$target"/*; do
    [ -L "$link" ] && [ ! -e "$link" ] && rm -f "$link"
  done

  while IFS=$'\t' read -r name path; do
    if [ -z "$path" ] || [ ! -d "$path" ]; then
      continue
    fi
    ln -sfn "$path" "$target/$name"
    count=$((count + 1))
  done < <(obot::config '.skills[]? | [.name, .path] | @tsv')

  [ "$count" -gt 0 ] && obot::log "linked $count skill(s) into $target"
  return 0
}
