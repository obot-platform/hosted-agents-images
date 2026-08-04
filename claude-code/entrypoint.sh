#!/usr/bin/env bash
# Boots Claude Code as an Obot hosted agent.
#
# Everything comes from /etc/obot/agent.json: the model endpoint, the MCP
# servers, the repository and the skills. This script knows nothing about Obot's
# address or routes -- it reads absolute URLs and credentials out of the config
# and translates them into what Claude Code expects.

set -euo pipefail
# shellcheck source=../lib/obot-agent.sh
source /usr/local/lib/obot-agent.sh

obot::require_config

# Claude Code speaks the Anthropic Messages API, so it needs a model Obot has
# resolved to that protocol; an OpenAI-compatible endpoint would not work here.
if IFS=$'\t' read -r model base_url api_key < <(obot::model anthropic); then
  # Claude Code builds "$ANTHROPIC_BASE_URL/v1/messages", so it wants the API
  # root -- while the config reports the endpoint a client posts to, which
  # already ends in /v1. Exported unchanged the two compose into /v1/v1/messages
  # and every request 404s. Claude Code reports that as a model it cannot
  # access, which points the reader at model access rather than at a URL.
  anthropic_base_url="${base_url%/}"
  export ANTHROPIC_BASE_URL="${anthropic_base_url%/v1}"
  export ANTHROPIC_AUTH_TOKEN="$api_key"
  export ANTHROPIC_MODEL="$model"
  obot::log "using model $model"
elif [ -z "${ANTHROPIC_AUTH_TOKEN:-}${ANTHROPIC_API_KEY:-}" ]; then
  # Claude Code speaks the Anthropic Messages API and nothing else, so an
  # installation with only OpenAI-backed models cannot run it. Failing here
  # surfaces that on the instance, where an administrator will see it. Starting
  # anyway leaves Claude Code sitting on an interactive login prompt that
  # nobody is watching, with the instance reporting itself healthy.
  obot::fail "this agent has no Anthropic-compatible model. Claude Code speaks the Anthropic API only; grant the agent a model from an Anthropic provider, or set ANTHROPIC_AUTH_TOKEN in the agent's environment."
fi

# Claude Code otherwise prompts for a login it must not perform: its identity
# here is the credential the config supplied.
export CLAUDE_CODE_SKIP_ONBOARDING=1
export DISABLE_AUTOUPDATER=1

# MCP servers, as --mcp-config expects them. The URLs and headers are copied
# straight across; no part of them is assembled here.
mcp_config="$HOME/.obot-mcp.json"
jq '{mcpServers: (reduce (.mcpServers[]? ) as $s ({};
      .[$s.name // $s.id] = ({type: "http", url: $s.url} + (if $s.headers then {headers: $s.headers} else {} end))))}' \
  <"$OBOT_CONFIG_FILE" >"$mcp_config"
chmod 600 "$mcp_config"
obot::log "configured $(jq -r '.mcpServers | length' <"$mcp_config") MCP server(s)"

# Claude Code keeps its history, projects and settings in the home directory,
# which is part of the image and is rebuilt on every restart. Relocating them
# onto the pool volume is what makes a session survive a redeploy.
obot::persist "$HOME/.claude" dir
obot::persist "$HOME/.claude.json" file

# Skills are already on disk; this only puts them where Claude Code looks.
obot::link_skills "$HOME/.claude/skills"

# Two statements, not `cd "$(obot::clone_source)"`: obot::fail inside a command
# substitution exits only the subshell, so a failed clone would leave `cd ""` --
# a silent no-op -- and the agent would start in the wrong directory with no
# repository. Assigning first makes set -e see the failure.
workdir="$(obot::clone_source)"
cd "$workdir"

# exec so Claude Code succeeds PID 1: it must receive the terminal and the
# signals directly, which is what makes the attached console usable.
exec claude --mcp-config "$mcp_config" "$@"
