#!/bin/bash
# Hermes backup script - reads config from config.yml
set -e

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="${SCRIPTS_DIR}/config.yml"
CREDS_FILE="${SCRIPTS_DIR}/.credentials"

# Load credentials from hidden file
if [ -f "$CREDS_FILE" ]; then
    source "$CREDS_FILE"
else
    echo "Error: Credentials file not found: $CREDS_FILE"
    exit 1
fi

# Load configuration
if [ ! -f "$CONFIG_FILE" ]; then
    echo "Error: Config file not found: $CONFIG_FILE"
    exit 1
fi

# Parse YAML-like config
HERMES_DIR="/data/.hermes"
BACKUP_BASE="/data/workspace/hermes-backups"
GITHUB_USER="chertopert1403"
GITHUB_REPO="chertopert1403/hermes-backup"

# Override with values from config.yml if set
while IFS='=' read -r key value; do
    [[ "$key" =~ ^#.*$ ]] && continue
    [[ -z "$key" ]] && continue
    export "$key=$value"
done < "$CONFIG_FILE"

if [ -z "$GITHUB_PAT" ]; then
    echo "Error: GITHUB_PAT not set in .credentials"
    exit 1
fi

REPO_DIR="/tmp/hermes-backup-${RANDOM}"
REPO_URL="https://${GITHUB_USER}:${GITHUB_PAT}@github.com/${GITHUB_REPO}.git"
TIMESTAMP=$(date --utc +"%Y%m%d_%H%M%S_UTC")
BACKUP_DIR="${BACKUP_BASE}/backup_${TIMESTAMP}"

echo "🔄 Starting Hermes backup: $TIMESTAMP"
echo "   Source: $HERMES_DIR"
echo "   Destination: $BACKUP_DIR"

mkdir -p "$BACKUP_DIR"

# 1. Memories
if [ -d "$HERMES_DIR/memories" ] && [ "$(ls -A $HERMES_DIR/memories 2>/dev/null)" ]; then
    cp -r "$HERMES_DIR/memories" "$BACKUP_DIR/"
    echo "  ✓ memories/"
fi

# 2. Skills (SKILL.md files only)
if [ -d "$HERMES_DIR/skills" ]; then
    mkdir -p "$BACKUP_DIR/skills"
    find "$HERMES_DIR/skills" -name "SKILL.md" | while read f; do
        rel_path="${f#$HERMES_DIR/}"
        mkdir -p "$BACKUP_DIR/$(dirname "$rel_path")"
        cp "$f" "$BACKUP_DIR/$(dirname "$rel_path")/"
    done
    echo "  ✓ skills/ (SKILL.md files)"
fi

# 3. Config
cp "$HERMES_DIR/config.yaml" "$BACKUP_DIR/" && echo "  ✓ config.yaml"

# 4. SOUL.md
cp "$HERMES_DIR/SOUL.md" "$BACKUP_DIR/" && echo "  ✓ SOUL.md"

# 5. Cron executions DB
if [ -f "$HERMES_DIR/cron/executions.db" ]; then
    cp "$HERMES_DIR/cron/executions.db" "$BACKUP_DIR/" && echo "  ✓ cron/executions.db"
fi
if [ -d "$HERMES_DIR/cron/output" ] && [ "$(ls -A $HERMES_DIR/cron/output 2>/dev/null)" ]; then
    cp -r "$HERMES_DIR/cron/output" "$BACKUP_DIR/cron_output" && echo "  ✓ cron/output/"
fi

# 6. Cron jobs config
if [ -f "$HERMES_DIR/cron/jobs.json" ]; then
    cp "$HERMES_DIR/cron/jobs.json" "$BACKUP_DIR/" && echo "  ✓ cron/jobs.json"
fi

# 7. Scripts
if [ -d "$HERMES_DIR/scripts" ]; then
    mkdir -p "$BACKUP_DIR/scripts"
    cp -r "$HERMES_DIR/scripts/"* "$BACKUP_DIR/scripts/" 2>/dev/null && echo "  ✓ scripts/"
fi

# 8. Gateway state
if [ -f "$HERMES_DIR/gateway_state.json" ]; then
    cp "$HERMES_DIR/gateway_state.json" "$BACKUP_DIR/" && echo "  ✓ gateway_state.json"
fi

# 9. Channel directory
if [ -f "$HERMES_DIR/channel_directory.json" ]; then
    cp "$HERMES_DIR/channel_directory.json" "$BACKUP_DIR/" && echo "  ✓ channel_directory.json"
fi

# 10. Kanban DB
if [ -f "$HERMES_DIR/kanban.db" ]; then
    cp "$HERMES_DIR/kanban.db" "$BACKUP_DIR/" && echo "  ✓ kanban.db"
fi

# 11. Provider models cache
if [ -f "$HERMES_DIR/provider_models_cache.json" ]; then
    cp "$HERMES_DIR/provider_models_cache.json" "$BACKUP_DIR/" && echo "  ✓ provider_models_cache.json"
fi

# 12. Skills prompt snapshot
if [ -f "$HERMES_DIR/.skills_prompt_snapshot.json" ]; then
    cp "$HERMES_DIR/.skills_prompt_snapshot.json" "$BACKUP_DIR/" && echo "  ✓ .skills_prompt_snapshot.json"
fi

# 13. Auth config (structure only - secrets redacted)
if [ -f "$HERMES_DIR/auth.json" ]; then
    python3 -c "
import json
with open('$HERMES_DIR/auth.json') as f:
    d = json.load(f)
if 'credential_pool' in d:
    for k in d['credential_pool']:
        d['credential_pool'][k] = ['**REDACTED**']
if 'providers' in d:
    d['providers'] = '**REDACTED**'
with open('$BACKUP_DIR/auth.json', 'w') as f:
    json.dump(d, f, indent=2)
" && echo "  ✓ auth.json (secrets redacted)"
fi

# 14. Sessions metadata
if [ -d "$HERMES_DIR/sessions" ] && [ "$(ls -A $HERMES_DIR/sessions 2>/dev/null)" ]; then
    mkdir -p "$BACKUP_DIR/sessions"
    cp "$HERMES_DIR/sessions"/*.json "$BACKUP_DIR/sessions/" 2>/dev/null && echo "  ✓ sessions/ (metadata)"
fi

# Write manifest
cat > "$BACKUP_DIR/MANIFEST.md" << EOF
# Hermes Backup - $TIMESTAMP

## Contents
$(for f in "$BACKUP_DIR"/*; do [ -e "$f" ] && echo "- $(basename "$f") ($(du -sh "$f" 2>/dev/null | cut -f1))"; done 2>/dev/null)

## Skills included
$(find "$BACKUP_DIR/skills" -name "SKILL.md" 2>/dev/null | sed 's|.*skills/|  - skills/|' | sed 's|/SKILL.md||')

## Scripts included
$(find "$BACKUP_DIR/scripts" -type f 2>/dev/null | sed 's|.*scripts/|  - scripts/|')

## Disk usage
$(du -sh "$BACKUP_DIR" | cut -f1) total

## Excluded
- state.db (contains session PAT tokens)
- models_dev_cache.json (regeneratable)
- Runtime files (pid, lock, heartbeat)

## Notes
- Auth tokens REDACTED in auth.json
- Full session binary logs NOT backed up
EOF

echo "  ✓ MANIFEST.md"

# === Commit & Push ===
rm -rf "$REPO_DIR"
git clone --quiet "$REPO_URL" "$REPO_DIR" 2>&1
cd "$REPO_DIR"

# Git config
git config user.email "backup@hermes.local"
git config user.name "Hermes Backup Bot"

# Copy ONLY backup content (NOT config.yml with credentials)
mkdir -p "$REPO_DIR/backups"
cp -r "$BACKUP_DIR"/* "$REPO_DIR/backups/"

# Add, commit and push
git add -A
git commit -m "Backup $TIMESTAMP" --quiet
git push --quiet 2>&1

# Cleanup
cd /
rm -rf "$REPO_DIR"

echo ""
echo "✅ Backup complete: $TIMESTAMP pushed to GitHub"