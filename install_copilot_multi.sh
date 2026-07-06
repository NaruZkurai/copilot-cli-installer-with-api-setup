#!/bin/sh

# Colors (use printf to embed real ESC chars for POSIX sh)
RED="$(printf '\033[0;31m')"
GREEN="$(printf '\033[0;32m')"
YELLOW="$(printf '\033[1;33m')"
NC="$(printf '\033[0m')"

CONFIG_DIR="/nzk/special/configs"
LOADER_SCRIPT="/nzk/special/loader.sh"
ALIASES_FILE="/nzk/special/aliases.sh"
FISH_LOADER="/nzk/special/loader.fish"
FISH_ALIASES="/nzk/special/aliases.fish"
DEFAULT_LINK="/nzk/special/default.conf"

# ── Parse --users flag for additional users to configure ──
ADDITIONAL_USERS=""
for arg in "$@"; do
    case "$arg" in
        --users=*)
            ADDITIONAL_USERS="${arg#--users=}"
            ;;
    esac
done

# ── Apply shell config for a specific user (for --users flag) ──
apply_for_user() {
    target_user="$1"
    target_home=$(eval echo "~$target_user" 2>/dev/null)
    if [ ! -d "$target_home" ]; then
        printf "%s%s%s\n" "${YELLOW}  ⚠️  Home for $target_user not found, skipping${NC}"
        return
    fi
    printf "%s%s%s\n" "${GREEN}  ➜ Applying configs for user: ${target_user}${NC}"

    # POSIX configs
    for cf in ".zshrc" ".bashrc" ".profile"; do
        cf_path="$target_home/$cf"
        if [ -f "$cf_path" ]; then
            sed -i '\|^export PATH="/nzk/bin:\$PATH"$|d' "$cf_path"
            sed -i '\|^export PATH="/nzk/appimages:\$PATH"$|d' "$cf_path"
            sed -i '\|^export PATH="/nzk/shellscripts:\$PATH"$|d' "$cf_path"
            sed -i '\|^export PATH="/nzk/executables:\$PATH"$|d' "$cf_path"
            # Add PATH if missing from current env
            path_add=""
            for dir in "/nzk/bin" "/nzk/appimages" "/nzk/shellscripts" "/nzk/executables"; do
                case ":${PATH}:" in *:"${dir}":*) ;; *) path_add="${path_add}${dir}:" ;; esac
            done
            [ -n "$path_add" ] && printf "export PATH=\"%s\$PATH\"\n" "${path_add%:}" >> "$cf_path"
            # Add loader source if missing
            if ! grep -qF "$ALIASES_FILE" "$cf_path" 2>/dev/null; then
                printf "\n# Copilot loader\n. \"%s\"\n" "$ALIASES_FILE" >> "$cf_path"
            fi
            printf "%s%s%s\n" "${GREEN}    ✓ ${cf}${NC}"
        fi
    done

    # Fish config
    fish_dir="$target_home/.config/fish"
    fish_cfg="$fish_dir/config.fish"
    if command -v fish >/dev/null 2>&1 || [ -f "$fish_cfg" ]; then
        mkdir -p "$fish_dir"
        [ -f "$fish_cfg" ] || touch "$fish_cfg"
        for dir in "/nzk/bin" "/nzk/appimages" "/nzk/shellscripts" "/nzk/executables"; do
            if ! grep -qFx "fish_add_path $dir" "$fish_cfg" 2>/dev/null; then
                printf "fish_add_path %s\n" "$dir" >> "$fish_cfg"
            fi
        done
        if ! grep -qF "$FISH_ALIASES" "$fish_cfg" 2>/dev/null; then
            printf "\n# Copilot loader\nsource \"%s\"\n" "$FISH_ALIASES" >> "$fish_cfg"
        fi
        printf "%s%s%s\n" "${GREEN}    ✓ config.fish${NC}"
    fi
}

# ── Create /nzk with sticky bit (create-only, no delete) ──
create_nzk_root() {
    if [ ! -d "/nzk" ]; then
        printf "%s%s%s\n" "${YELLOW}📁 Creating /nzk with sticky bit...${NC}"
        sudo mkdir -p /nzk
        sudo chmod 1777 /nzk
        printf "%s%s%s\n" "${GREEN}  ✓ /nzk created with sticky bit (create-only)${NC}"
    else
        current_perms=$(stat -c %a /nzk 2>/dev/null || stat -f %A /nzk 2>/dev/null)
        if [ "$current_perms" != "1777" ]; then
            printf "%s%s%s\n" "${YELLOW}⚠️  Fixing /nzk permissions...${NC}"
            sudo chmod 1777 /nzk
            printf "%s%s%s\n" "${GREEN}  ✓ Sticky bit applied${NC}"
        fi
    fi
}

# ── Create subdirectory with sticky bit ──
create_sticky_dir() {
    dir="$1"
    if [ ! -d "$dir" ]; then
        printf "%s%s%s\n" "${YELLOW}📁 Creating ${dir}...${NC}"
        sudo mkdir -p "$dir"
        sudo chmod 1777 "$dir"
        printf "%s%s%s\n" "${GREEN}  ✓ ${dir} created with sticky bit${NC}"
    else
        current_perms=$(stat -c %a "$dir" 2>/dev/null || stat -f %A "$dir" 2>/dev/null)
        if [ "$current_perms" != "1777" ]; then
            sudo chmod 1777 "$dir"
            printf "%s%s%s\n" "${GREEN}  ✓ Sticky bit applied to ${dir}${NC}"
        fi
    fi
}

# ── Detect Fish shell ──
FISH_SHELL=false
FISH_INSTALLED=false
[ -n "$FISH_VERSION" ] && FISH_SHELL=true
printf '%s\n' "${SHELL:-}" | grep -qi fish && FISH_SHELL=true
command -v fish >/dev/null 2>&1 && FISH_INSTALLED=true

# ── Safe prompt: print prompt, read input, exit on EOF ──
prompt() {
    printf "%s " "$1"
    if ! read "$2"; then
        # EOF (piped input or closed stdin) — exit gracefully
        echo ""
        exit 0
    fi
}

# ── Read API key: show first 3 chars live, then * per char ──
read_silent() {
    var_name="$1"
    input=""
    count=0
    old_stty=$(stty -g 2>/dev/null)
    # Always restore terminal on exit (even from Ctrl+C)
    trap 'stty "$old_stty" 2>/dev/null' EXIT
    stty -icanon min 1 time 0 -echo 2>/dev/null

    while :; do
        c=$(dd bs=1 count=1 2>/dev/null)
        case "$c" in
            "")
                # EOF / closed pipe
                break
                ;;
            "$(printf '\n')"|"$(printf '\r')")
                printf '\n'
                break
                ;;
            "$(printf '\b')"|"$(printf '\177')")
                # Backspace (BS or DEL)
                if [ "$count" -gt 0 ]; then
                    input="${input%?}"
                    count=$((count - 1))
                    printf '\b \b'
                fi
                ;;
            "$(printf '\004')")
                # Ctrl+D — abort
                printf '\n'
                input=""
                break
                ;;
            *)
                input="${input}${c}"
                count=$((count + 1))
                if [ "$count" -le 3 ]; then
                    printf '%s' "$c"
                else
                    printf '*'
                fi
                ;;
        esac
    done

    stty "$old_stty" 2>/dev/null
    eval "$var_name=\$input"
}

# ── Confirm: loop until valid y/n/empty, default is no ──
confirm() {
    prompt_text="$1"
    while :; do
        printf "%s (y/N): " "$prompt_text"
        if ! read answer; then
            echo ""
            exit 0
        fi
        case "$answer" in
            y|Y) return 0 ;;
            n|N) return 1 ;;
            "")  return 1 ;;
            *)   printf "  Please answer y or n.\n" ;;
        esac
    done
}

# ── Slugify a model name ──
slugify() {
    printf '%s\n' "$1" | sed 's/[^a-zA-Z0-9_-]/-/g' | tr '[:upper:]' '[:lower:]'
}

# ── Escape a value for use in sed replacement (delimiter: |) ──
escape_sed() {
    printf '%s\n' "$1" | sed 's/[\\&|]/\\&/g'
}

# ── List models with numbers ──
list_models() {
    i=1
    for f in "$CONFIG_DIR"/*.conf; do
        [ -f "$f" ] || continue
        model=$(sed -n 's/^export COPILOT_MODEL=//p' "$f")
        label=$(sed -n 's/^# Provider: //p' "$f")
        printf "  %d) %-30s [%s]\n" "$i" "$model" "${label:-unknown}"
        i=$((i + 1))
    done
    [ "$i" -eq 1 ] && echo "  (none)"
}

count_models() {
    ls "$CONFIG_DIR"/*.conf 2>/dev/null | wc -l
}

# ──────────────────────────────────────────────
# Detection
# ──────────────────────────────────────────────

CLI_EXISTS=false
CONFIG_EXISTS=false

detect_existing() {
    copilot_path=$(command -v copilot 2>/dev/null)
    # Also check common install dirs not necessarily in PATH
    for _p in ~/.local/bin/copilot /usr/local/bin/copilot /nzk/bin/copilot; do
        if [ -f "$_p" ] && [ -z "$copilot_path" ]; then
            copilot_path="$_p"
            break
        fi
    done
    if [ -n "$copilot_path" ]; then
        CLI_EXISTS=true
        printf "%s%s%s\n" "${GREEN}✓ Detected:${NC} copilot CLI at $copilot_path"
    fi
    if [ -d "$CONFIG_DIR" ] && [ "$(count_models)" -gt 0 ]; then
        CONFIG_EXISTS=true
        printf "%s%s%s\n" "${GREEN}✓ Detected:${NC} $(count_models) model config(s) in $CONFIG_DIR"
    fi
    if ! $CLI_EXISTS && ! $CONFIG_EXISTS; then
        printf "%s%s%s\n" "${YELLOW}ℹ️  No existing installation detected.${NC}"
    fi
    echo ""
}

# ──────────────────────────────────────────────
# CLI Install
# ──────────────────────────────────────────────

install_copilot() {
    if $CLI_EXISTS; then
        copilot_path=$(command -v copilot 2>/dev/null)
        printf "%s%s%s\n" "${YELLOW}⚠️  Copilot CLI already installed at ${copilot_path:-/nzk/bin/copilot}.${NC}"
        if ! confirm "Reinstall?"; then
            printf "%s%s%s\n" "${GREEN}⏭️  Skipping copilot install.${NC}"
            return 0
        fi
    fi

    printf "%s%s%s\n" "${YELLOW}📥 Installing GitHub Copilot CLI...${NC}"
    # Pipe "n" to skip the installer's PATH prompt — we handle PATH ourselves
    printf "n\n" | curl -fsSL https://gh.io/copilot-install | bash

    # Create /nzk with sticky bit
    create_nzk_root
    create_sticky_dir "/nzk/bin"

    printf "%s%s%s\n" "${YELLOW}📦 Moving copilot to /nzk/bin...${NC}"
    if [ -f ~/.local/bin/copilot ]; then
        sudo mv ~/.local/bin/copilot /nzk/bin/copilot
    elif [ -f /usr/local/bin/copilot ]; then
        sudo mv /usr/local/bin/copilot /nzk/bin/copilot
    else
        printf "%s%s%s\n" "${RED}❌ Copilot binary not found after installation!${NC}"
        printf "%s%s%s\n" "${YELLOW}   Please manually move it to /nzk/bin/copilot${NC}"
        return 1
    fi
    sudo chmod +x /nzk/bin/copilot
    printf "%s%s%s\n" "${GREEN}✅ Copilot installed at /nzk/bin/copilot${NC}"
}

# ──────────────────────────────────────────────
# Provider chooser
# ──────────────────────────────────────────────

choose_provider() {
    echo ""
    echo "Select a provider:"
    echo "  0) DeepSeek    (default=deepseek-v4-flash)"
    echo "  1) DeepSeek    (default=deepseek-v4-pro)"
    echo "  2) OpenAI      (gpt-4o, o3, etc.)"
    echo "  3) Anthropic   (claude-sonnet-4-20250514, etc.)"
    echo "  4) Google      (gemini-2.5-pro, etc.)"
    echo "  5) Custom      (enter your own)"
    echo ""
    while :; do
        prompt "Enter your choice [0-5]:" prov_choice
        case $prov_choice in
            0)
                PROVIDER_TYPE="anthropic"
                PROVIDER_BASE_URL="https://api.deepseek.com/anthropic"
                PROVIDER_LABEL="DeepSeek"
                PROVIDER_MODEL="deepseek-v4-flash"
                break
                ;;
            1)
                PROVIDER_TYPE="anthropic"
                PROVIDER_BASE_URL="https://api.deepseek.com/anthropic"
                PROVIDER_LABEL="DeepSeek"
                PROVIDER_MODEL="deepseek-v4-pro"
                break
                ;;
            2)
                PROVIDER_TYPE="openai"
                PROVIDER_BASE_URL="https://api.openai.com/v1"
                PROVIDER_LABEL="OpenAI"
                prompt "Model name (Enter=gpt-4o):" PROVIDER_MODEL
                [ -z "$PROVIDER_MODEL" ] && PROVIDER_MODEL="gpt-4o"
                break
                ;;
            3)
                PROVIDER_TYPE="anthropic"
                PROVIDER_BASE_URL="https://api.anthropic.com/v1"
                PROVIDER_LABEL="Anthropic"
                prompt "Model name (Enter=claude-sonnet-4-20250514):" PROVIDER_MODEL
                [ -z "$PROVIDER_MODEL" ] && PROVIDER_MODEL="claude-sonnet-4-20250514"
                break
                ;;
            4)
                PROVIDER_TYPE="google"
                PROVIDER_BASE_URL="https://generativelanguage.googleapis.com/v1/openai"
                PROVIDER_LABEL="Google"
                prompt "Model name (Enter=gemini-2.5-pro):" PROVIDER_MODEL
                [ -z "$PROVIDER_MODEL" ] && PROVIDER_MODEL="gemini-2.5-pro"
                break
                ;;
            5)
                PROVIDER_LABEL="Custom"
                prompt "Enter provider type (e.g. anthropic, openai):" PROVIDER_TYPE
                prompt "Enter base URL (e.g. https://api.example.com/v1):" PROVIDER_BASE_URL
                prompt "Enter model name:" PROVIDER_MODEL
                break
                ;;
            q|Q) return 1 ;;
            *) printf "  Invalid choice. Enter 0-5 or q to cancel.\n" ;;
        esac
    done
}

# ──────────────────────────────────────────────
# Write one config file
# ──────────────────────────────────────────────

write_config() {
    model="$1"
    ptype="$2"
    base_url="$3"
    label="$4"
    key="$5"
    slug=$(slugify "$model")
    file="${CONFIG_DIR}/${slug}.conf"
    fish_file="${CONFIG_DIR}/${slug}.fish"

    # Escape single quotes in key: ' -> '\'', so the value is safe in single quotes
    sq="'"
    key_escaped=$(printf '%s\n' "$key" | sed "s/$sq/$sq\\\\$sq$sq/g")

    # POSIX/sh version
    cat > "$file" << EOF
# Copilot Configuration
# Generated: $(date)
# Provider: ${label}

export COPILOT_PROVIDER_TYPE=${ptype}
export COPILOT_PROVIDER_BASE_URL=${base_url}
export COPILOT_PROVIDER_API_KEY='${key_escaped}'
export COPILOT_MODEL=${model}
EOF
    chmod 600 "$file"

    # Fish version
    cat > "$fish_file" << EOF
# Copilot Configuration — Fish
# Generated: $(date)
# Provider: ${label}

set -gx COPILOT_PROVIDER_TYPE ${ptype}
set -gx COPILOT_PROVIDER_BASE_URL ${base_url}
set -gx COPILOT_PROVIDER_API_KEY '${key_escaped}'
set -gx COPILOT_MODEL ${model}
EOF
    chmod 600 "$fish_file"

    echo "$slug"
}

# ──────────────────────────────────────────────
# Regenerate loader script
# ──────────────────────────────────────────────

regenerate_loader() {
    first=true
    rm -f "$DEFAULT_LINK"

    # ── POSIX loader (sh/bash/zsh): just sources the default model config ──
    : > "$LOADER_SCRIPT"
    printf "%s\n" "# Copilot default model config — auto-generated" > "$LOADER_SCRIPT"

    for f in "$CONFIG_DIR"/*.conf; do
        [ -f "$f" ] || continue
        if $first; then
            echo ". \"$f\"" >> "$LOADER_SCRIPT"
            ln -sf "$f" "$DEFAULT_LINK"
            first=false
        fi
    done
    printf "\n# Caveman instructions dir\n" >> "$LOADER_SCRIPT"
    printf "export COPILOT_CUSTOM_INSTRUCTIONS_DIRS=/nzk/special\n" >> "$LOADER_SCRIPT"

    chmod 644 "$LOADER_SCRIPT" 2>/dev/null
    printf "%s\n" "# Copilot default model config" > "$ALIASES_FILE"
    printf ". \"%s\"\n" "$LOADER_SCRIPT" >> "$ALIASES_FILE"
    chmod 644 "$ALIASES_FILE" 2>/dev/null

    # ── Fish loader: just sources the default model config ──
    : > "$FISH_LOADER"
    printf "%s\n" "# Copilot default model config for Fish — auto-generated" > "$FISH_LOADER"

    first_fish=true
    for f in "$CONFIG_DIR"/*.fish; do
        [ -f "$f" ] || continue
        if $first_fish; then
            printf "source \"%s\"\n" "$f" >> "$FISH_LOADER"
            first_fish=false
        fi
    done
    printf "\n# Caveman instructions dir\n" >> "$FISH_LOADER"
    printf "set -gx COPILOT_CUSTOM_INSTRUCTIONS_DIRS /nzk/special\n" >> "$FISH_LOADER"

    chmod 644 "$FISH_LOADER" 2>/dev/null
    printf "%s\n" "# Copilot default model config for Fish" > "$FISH_ALIASES"
    printf "source \"%s\"\n" "$FISH_LOADER" >> "$FISH_ALIASES"
    chmod 644 "$FISH_ALIASES" 2>/dev/null
}

# ──────────────────────────────────────────────
# Offline mode — skip GitHub login, use local provider
# ──────────────────────────────────────────────

setup_offline() {
    printf "%s%s%s\n" "${YELLOW}🔌 Enabling offline mode (no GitHub login)...${NC}"

    # Add COPILOT_OFFLINE=true to POSIX loader
    if ! grep -qF "COPILOT_OFFLINE" "$LOADER_SCRIPT" 2>/dev/null; then
        printf "\n# Offline mode — skip GitHub login\n" >> "$LOADER_SCRIPT"
        printf "export COPILOT_OFFLINE=true\n" >> "$LOADER_SCRIPT"
    fi
    if ! grep -qF "COPILOT_OFFLINE" "$ALIASES_FILE" 2>/dev/null; then
        printf "\nexport COPILOT_OFFLINE=true\n" >> "$ALIASES_FILE"
    fi

    # Add to Fish loader
    if $FISH_INSTALLED || [ -f "$FISH_LOADER" ]; then
        if ! grep -qF "COPILOT_OFFLINE" "$FISH_LOADER" 2>/dev/null; then
            printf "\n# Offline mode\n" >> "$FISH_LOADER"
            printf "set -gx COPILOT_OFFLINE true\n" >> "$FISH_LOADER"
        fi
        if ! grep -qF "COPILOT_OFFLINE" "$FISH_ALIASES" 2>/dev/null; then
            printf "\nset -gx COPILOT_OFFLINE true\n" >> "$FISH_ALIASES"
        fi
    fi

    # Also ensure the aliases file is sourced in shell configs
    for cf in "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.profile"; do
        if [ -f "$cf" ] && ! grep -qF "$ALIASES_FILE" "$cf" 2>/dev/null; then
            {
                echo ""
                echo "# Copilot loader"
                echo ". \"${ALIASES_FILE}\""
            } >> "$cf"
            printf "%s%s%s\n" "${GREEN}  ✓ Added loader source to ${cf}${NC}"
        fi
    done
    # Also ensure fish config sources the fish aliases
    if $FISH_INSTALLED; then
        fish_cfg="$HOME/.config/fish/config.fish"
        mkdir -p "$HOME/.config/fish"
        [ -f "$fish_cfg" ] || touch "$fish_cfg"
        if ! grep -qF "$FISH_ALIASES" "$fish_cfg" 2>/dev/null; then
            {
                echo ""
                echo "# Copilot loader"
                echo "source \"$FISH_ALIASES\""
            } >> "$fish_cfg"
            printf "%s%s%s\n" "${GREEN}  ✓ Added fish loader source to ${fish_cfg}${NC}"
        fi
    fi

    printf "%s%s%s\n" "${GREEN}✅ Offline mode enabled. Copilot will skip GitHub login.${NC}"
    printf "%s%s%s\n" "${YELLOW}   Requires COPILOT_PROVIDER_BASE_URL (local model).${NC}"
    printf "%s%s%s\n" "${YELLOW}   Run '. ~/.bashrc' or open a new terminal.${NC}"
}

# ──────────────────────────────────────────────
# Install the Copilot plugin for model management
# ──────────────────────────────────────────────

setup_plugin() {
    plugin_dir="/nzk/special/plugin"
    skill_dir="$plugin_dir/skills/manage-models"
    create_sticky_dir "$skill_dir"

    # Build a dynamic model list for the skill instructions
    model_list=""
    for f in "$CONFIG_DIR"/*.conf; do
        [ -f "$f" ] || continue
        slug=$(basename "$f" .conf)
        model=$(sed -n 's/^export COPILOT_MODEL=//p' "$f")
        model_list="${model_list}   - ${slug}: ${model}\n"
    done
    [ -z "$model_list" ] && model_list="   (none configured yet)\n"

    # Write plugin manifest
    cat > "$plugin_dir/plugin.json" << EOF
{
  "name": "copilot-model-manager",
  "description": "Manage Copilot model configurations from within Copilot",
  "version": "1.0.0",
  "author": { "name": "Copilot Configurator" },
  "skills": ["skills/"]
}
EOF

    # Write skill
    cat > "$skill_dir/SKILL.md" << SKILLEOF
---
name: manage-models
description: Manage Copilot model provider configurations stored in /nzk/special/configs/
---

# Manage Copilot Models

Model config files live in \`/nzk/special/configs/\`. Each \`.conf\` file has:

- \`COPILOT_PROVIDER_TYPE\` — "openai", "anthropic", "azure", or "google"
- \`COPILOT_PROVIDER_BASE_URL\` — API endpoint
- \`COPILOT_PROVIDER_API_KEY\` — API key
- \`COPILOT_MODEL\` — model name

## Currently configured models
${model_list}
## Provider presets
- DeepSeek:    type=anthropic,   url=https://api.deepseek.com/anthropic
- OpenAI:      type=openai,      url=https://api.openai.com/v1
- Anthropic:   type=anthropic,   url=https://api.anthropic.com/v1
- Google:      type=google,      url=https://generativelanguage.googleapis.com/v1/openai

## What the user can ask you
- "List my models" — read and show all \`.conf\` files
- "Add a model" — ask for provider, model name, API key; write both \`.conf\` and \`.fish\`
- "Remove a model" — pick one, delete its files
- "Switch to <model>" or "Use <model>" — update \`/nzk/special/loader.sh\` and \`/nzk/special/loader.fish\` to source that model's config instead of the current default. This makes \`copilot\` use that model on next launch.
- "Set <model> as default" — same as switch

The default model is determined by which config file is sourced first in \`/nzk/special/loader.sh\` (POSIX) and \`/nzk/special/loader.fish\` (Fish). To switch, edit the loader to source a different \`.conf\`/\`.fish\` file first.

When you add, remove, or switch models, tell the user to run:
\`\`\`
copilot plugin install /nzk/special/plugin
\`\`\`
to reload the config.
SKILLEOF

    # ── Caveman skill: enables /caveman as a slash command ──
    caveman_skill_dir="$plugin_dir/skills/caveman"
    create_sticky_dir "$caveman_skill_dir"
    cat > "$caveman_skill_dir/SKILL.md" << 'CAVEMANSKILL'
---
name: caveman
description: Switch caveman response mode levels - lite, full, ultra, or wenyan. Invoke with /caveman <level> to set terseness.
---

# Caveman Mode

Switch response mode to caveman-speak at the specified level.

## Levels
- **lite**: Moderate terseness — drop filler words, keep structure.
- **full** (default): Full caveman — drop articles, filler, pleasantries. Fragments OK.
- **ultra**: Maximum terseness — shortest possible answers. Code only when relevant.
- **wenyan**: Classical Chinese (文言文) style.

When invoked, switch to the specified level and confirm in one line.
CAVEMANSKILL
    chmod 644 "$caveman_skill_dir/SKILL.md"

    # Install / reinstall the plugin (always reinstalls to refresh the model list)
    copilot_path=$(command -v copilot 2>/dev/null)
    for _p in /nzk/bin/copilot ~/.local/bin/copilot /usr/local/bin/copilot; do
        if [ -f "$_p" ] && [ -z "$copilot_path" ]; then
            copilot_path="$_p"
        fi
    done
    if [ -n "$copilot_path" ]; then
        "$copilot_path" plugin install "$plugin_dir" >/dev/null 2>&1
        printf "%s%s%s\n" "${GREEN}  ✓ Copilot plugin updated${NC}"
    else
        printf "%s%s%s\n" "${YELLOW}  ⚠️  copilot binary not found — plugin not installed${NC}"
    fi
}

# ──────────────────────────────────────────────
# Install caveman (terse output mode via copilot-instructions)
# ──────────────────────────────────────────────

setup_caveman() {
    caveman_file="/nzk/special/copilot-instructions.md"
    cat > "$caveman_file" << 'CAVEMANEOF'
Respond terse like smart caveman. All technical substance stay. Only fluff die.

Rules:
- Drop: articles (a/an/the), filler (just/really/basically), pleasantries, hedging
- Fragments OK. Short synonyms. Technical terms exact. Code unchanged.
- Pattern: [thing] [action] [reason]. [next step].
- Not: "Sure! I'd be happy to help you with that."
- Yes: "Bug in auth middleware. Fix:"

Switch level: /caveman lite|full|ultra|wenyan
Stop: "stop caveman" or "normal mode"

Auto-Clarity: drop caveman for security warnings, irreversible actions, user confused. Resume after.

Boundaries: code/PRs written normal. Commits use caveman-speak — terse, no filler, [action] [scope] [reason].
CAVEMANEOF
    chmod 644 "$caveman_file"
    printf "%s%s%s\n" "${GREEN}  ✓ Caveman mode active (terse output)${NC}"
}

# ──────────────────────────────────────────────
# Add one model
# ──────────────────────────────────────────────

add_model() {
    choose_provider || return 1
    echo ""
    printf "%s%s%s\n" "${YELLOW}🔑 Enter API key for ${PROVIDER_MODEL}:${NC}"
    read_silent api_key
    if [ -z "$api_key" ]; then
        printf "%s%s%s\n" "${RED}❌ No key entered. Skipping.${NC}"
        return 1
    fi

    create_sticky_dir "$CONFIG_DIR"
    slug=$(write_config "$PROVIDER_MODEL" "$PROVIDER_TYPE" "$PROVIDER_BASE_URL" "$PROVIDER_LABEL" "$api_key")
    printf "%s%s%s\n" "${GREEN}  ✓ Added: ${PROVIDER_MODEL} → ${slug}.conf${NC}"
}

# ──────────────────────────────────────────────
# Full setup
# ──────────────────────────────────────────────

setup_api_keys() {
    create_sticky_dir "$CONFIG_DIR"

    if $CONFIG_EXISTS; then
        echo ""
        printf "%s%s%s\n" "${YELLOW}⚠️  Configs already exist ($(count_models) models)${NC}"
        echo "  1) Start fresh (remove all and re-add)"
        echo "  2) Add more models"
        echo "  3) Skip"
        echo "  q) Cancel"
        while :; do
            prompt "Enter your choice [1-3]:" cfg_choice
            case $cfg_choice in
                1)
                    rm -f "$CONFIG_DIR"/*.conf "$CONFIG_DIR"/*.fish
                    CONFIG_EXISTS=false
                    break
                    ;;
                2)
                    add_model || return 0
                    regenerate_loader
                    setup_plugin
                    setup_caveman
                    printf "%s%s%s\n" "${GREEN}✅ Model added.${NC}"
                    return 0
                    ;;
                3)
                    printf "%s%s%s\n" "${GREEN}⏭️  Skipping.${NC}"
                    return 0
                    ;;
                q|Q)
                    printf "%s%s%s\n" "${GREEN}⏭️  Cancelled.${NC}"
                    return 0
                    ;;
                *) printf "  Invalid choice. Enter 1, 2, 3, or q.\n" ;;
            esac
        done
    fi

    printf "%s%s%s\n" "${YELLOW}📝 Let's add some models. You can add as many as you want.${NC}"
    echo ""
    add_model || return

    while :; do
        echo ""
        if confirm "Add another model?"; then
            add_model || break
        else
            break
        fi
    done

    regenerate_loader
    setup_plugin
    setup_caveman
    printf "%s%s%s\n" "${GREEN}✅ All models configured.${NC}"
}

# ──────────────────────────────────────────────
# Update keys in existing configs
# ──────────────────────────────────────────────

update_keys_only() {
    create_sticky_dir "$CONFIG_DIR"
    count=$(count_models)

    if [ "$count" -eq 0 ]; then
        printf "%s%s%s\n" "${RED}❌ No existing configs found. Starting fresh.${NC}"
        setup_api_keys
        return
    fi

    echo ""
    printf "%s%s%s\n" "${YELLOW}📋 Existing models:${NC}"
    list_models
    echo ""
    while :; do
        prompt "Which model? (number, 'a' for all, 'n' for new, 'q' to quit):" upd

        if [ "$upd" = "q" ] || [ "$upd" = "Q" ]; then
            printf "%s%s%s\n" "${GREEN}⏭️  Cancelled.${NC}"
            return
        fi

        if [ "$upd" = "n" ] || [ "$upd" = "N" ]; then
            add_model
            regenerate_loader
            setup_plugin
            setup_caveman
            printf "%s%s%s\n" "${GREEN}✅ New model added.${NC}"
            return
        fi

        if [ "$upd" = "a" ] || [ "$upd" = "A" ]; then
            for f in "$CONFIG_DIR"/*.conf; do
                [ -f "$f" ] || continue
                model=$(sed -n 's/^export COPILOT_MODEL=//p' "$f")
                printf "%s%s%s\n" "${YELLOW}🔑 New API key for ${model}:${NC}"
                read_silent new_key
                if [ -n "$new_key" ]; then
                    escaped_key=$(escape_sed "$new_key")
                    sed -i "s|^export COPILOT_PROVIDER_API_KEY=.*|export COPILOT_PROVIDER_API_KEY=${escaped_key}|" "$f"
                    slug=$(basename "$f" .conf)
                    fish_file="${CONFIG_DIR}/${slug}.fish"
                    if [ -f "$fish_file" ]; then
                        sed -i "s|^set -gx COPILOT_PROVIDER_API_KEY .*|set -gx COPILOT_PROVIDER_API_KEY ${escaped_key}|" "$fish_file"
                    fi
                    printf "%s%s%s\n" "${GREEN}  ✓ Updated ${model}${NC}"
                fi
            done
            printf "%s%s%s\n" "${GREEN}✅ All keys updated.${NC}"
            return
        fi

        # Single model by number
        idx=0
        target=""
        for f in "$CONFIG_DIR"/*.conf; do
            [ -f "$f" ] || continue
            idx=$((idx + 1))
            if [ "$idx" -eq "$upd" ]; then
                target="$f"
                break
            fi
        done

        [ -n "$target" ] && break
        printf "  Invalid selection.\n"
    done

    model=$(sed -n 's/^export COPILOT_MODEL=//p' "$target")
    current_key=$(sed -n 's/^export COPILOT_PROVIDER_API_KEY=//p' "$target")

    printf "%s%s%s\n" "${YELLOW}🔑 New API key for ${model} (blank = keep):${NC}"
    read_silent new_key

    # Edit model name?
    if confirm "Edit model name?"; then
        printf "%s%s%s\n" "${YELLOW}Current model: ${model}${NC}"
        prompt "New model name:" new_model
        if [ -n "$new_model" ] && [ "$new_model" != "$model" ]; then
            sed -i "s|^export COPILOT_MODEL=.*|export COPILOT_MODEL=${new_model}|" "$target"
            new_slug=$(slugify "$new_model")
            new_file="${CONFIG_DIR}/${new_slug}.conf"
            if [ "$new_file" != "$target" ]; then
                old_slug=$(basename "$target" .conf)
                mv "$target" "$new_file"
                target="$new_file"
                # Also rename fish file
                old_fish="${CONFIG_DIR}/${old_slug}.fish"
                new_fish="${CONFIG_DIR}/${new_slug}.fish"
                if [ -f "$old_fish" ]; then
                    mv "$old_fish" "$new_fish"
                fi
                printf "%s%s%s\n" "${GREEN}  ✓ Renamed config to ${new_slug}.conf${NC}"
            fi
            model="$new_model"
        fi
    fi

    # Apply key update
    if [ -n "$new_key" ]; then
        escaped_key=$(escape_sed "$new_key")
        sed -i "s|^export COPILOT_PROVIDER_API_KEY=.*|export COPILOT_PROVIDER_API_KEY=${escaped_key}|" "$target"
        slug=$(basename "$target" .conf)
        fish_file="${CONFIG_DIR}/${slug}.fish"
        if [ -f "$fish_file" ]; then
            sed -i "s|^set -gx COPILOT_PROVIDER_API_KEY .*|set -gx COPILOT_PROVIDER_API_KEY ${escaped_key}|" "$fish_file"
        fi
        printf "%s%s%s\n" "${GREEN}  ✓ Key updated${NC}"
    else
        new_key="$current_key"
    fi

    # Update provider settings?
    if confirm "Update provider settings too?"; then
        choose_provider
        # Escape single quotes in key for safe embedding in single quotes
        sq="'"
        key_escaped=$(printf '%s\n' "$new_key" | sed "s/$sq/$sq\\\\$sq$sq/g")
        # Write updated .conf
        cat > "$target" << EOF
# Copilot Configuration
# Generated: $(date)
# Provider: ${PROVIDER_LABEL}

export COPILOT_PROVIDER_TYPE=${PROVIDER_TYPE}
export COPILOT_PROVIDER_BASE_URL=${PROVIDER_BASE_URL}
export COPILOT_PROVIDER_API_KEY='${key_escaped}'
export COPILOT_MODEL=${PROVIDER_MODEL}
EOF
        # Write updated .fish
        slug=$(basename "$target" .conf)
        fish_file="${CONFIG_DIR}/${slug}.fish"
        cat > "$fish_file" << EOF
# Copilot Configuration — Fish
# Generated: $(date)
# Provider: ${PROVIDER_LABEL}

set -gx COPILOT_PROVIDER_TYPE ${PROVIDER_TYPE}
set -gx COPILOT_PROVIDER_BASE_URL ${PROVIDER_BASE_URL}
set -gx COPILOT_PROVIDER_API_KEY '${key_escaped}'
set -gx COPILOT_MODEL ${PROVIDER_MODEL}
EOF
        new_slug=$(slugify "$PROVIDER_MODEL")
        new_file="${CONFIG_DIR}/${new_slug}.conf"
        if [ "$new_file" != "$target" ]; then
            old_fish="${CONFIG_DIR}/${slug}.fish"
            new_fish="${CONFIG_DIR}/${new_slug}.fish"
            mv "$target" "$new_file"
            [ -f "$old_fish" ] && mv "$old_fish" "$new_fish"
            printf "%s%s%s\n" "${GREEN}  ✓ Renamed to ${new_slug}.conf${NC}"
        fi
    fi

    regenerate_loader
    setup_plugin
    setup_caveman
    printf "%s%s%s\n" "${GREEN}✅ Updated.${NC}"
}

# ──────────────────────────────────────────────
# Shell config
# ──────────────────────────────────────────────

setup_shell_config() {
    printf "%s%s%s\n" "${YELLOW}⚙️  Adding to shell config...${NC}"

    # ── Helper: update one POSIX config file ──
    update_posix_config() {
        cf="$1"
        cp "$cf" "${cf}.backup" 2>/dev/null

        # Remove any previous nzk PATH lines added by this installer
        sed -i '\|^export PATH="/nzk/bin:\$PATH"$|d' "$cf"
        sed -i '\|^export PATH="/nzk/appimages:\$PATH"$|d' "$cf"
        sed -i '\|^export PATH="/nzk/shellscripts:\$PATH"$|d' "$cf"
        sed -i '\|^export PATH="/nzk/executables:\$PATH"$|d' "$cf"

        # Determine which dirs are missing from the current PATH
        PATH_ADD=""
        for dir in "/nzk/bin" "/nzk/appimages" "/nzk/shellscripts" "/nzk/executables"; do
            case ":${PATH}:" in
                *:"${dir}":*)
                    printf "%s%s%s\n" "${YELLOW}  ✓ ${dir} already in PATH${NC}"
                    ;;
                *)
                    PATH_ADD="${PATH_ADD}${dir}:"
                    ;;
            esac
        done

        modified=false

        if [ -n "$PATH_ADD" ]; then
            PATH_ADD="${PATH_ADD%:}"
            echo "export PATH=\"${PATH_ADD}:\$PATH\"" >> "$cf"
            printf "%s%s%s\n" "${GREEN}  ✓ Added ${PATH_ADD} to PATH in ${cf}${NC}"
            modified=true
        fi

        if ! grep -qF "# Copilot loader" "$cf" 2>/dev/null; then
            {
                echo ""
                echo "# Copilot loader"
                echo ". \"${ALIASES_FILE}\""
            } >> "$cf"
            printf "%s%s%s\n" "${GREEN}  ✓ Added loader source to ${cf}${NC}"
            modified=true
        else
            printf "%s%s%s\n" "${YELLOW}  ✓ Loader already sourced${NC}"
        fi

        if $modified; then
            printf "%s%s%s\n" "${GREEN}✅ ${cf} updated. Run: . ${cf}${NC}"
        else
            printf "%s%s%s\n" "${GREEN}✅ ${cf} is already up to date.${NC}"
        fi
    }

    # ── POSIX branch — update ALL existing config files ──
    posix_updated=false
    for cf in "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.profile"; do
        if [ -f "$cf" ]; then
            [ "$posix_updated" = false ] && echo "" && posix_updated=true
            update_posix_config "$cf"
        fi
    done
    if [ "$posix_updated" = false ]; then
        printf "%s%s%s\n" "${RED}❌ No .zshrc, .bashrc, or .profile found!${NC}"
    fi

    # ── Fish branch — also run if fish is installed ──
    if $FISH_INSTALLED; then
        echo ""
        mkdir -p ~/.config/fish
        FISH_CONFIG=~/.config/fish/config.fish
        [ -f "$FISH_CONFIG" ] && cp "$FISH_CONFIG" "${FISH_CONFIG}.backup" 2>/dev/null

        for dir in "/nzk/bin" "/nzk/appimages" "/nzk/shellscripts" "/nzk/executables"; do
            if grep -qFx "fish_add_path $dir" "$FISH_CONFIG" 2>/dev/null; then
                printf "%s%s%s\n" "${YELLOW}  ✓ ${dir} already in fish PATH${NC}"
            else
                printf "fish_add_path %s\n" "$dir" >> "$FISH_CONFIG"
                printf "%s%s%s\n" "${GREEN}  ✓ Added ${dir} to fish PATH${NC}"
            fi
        done

        loader_line="source \"$FISH_ALIASES\""
        if grep -qFx "$loader_line" "$FISH_CONFIG" 2>/dev/null; then
            printf "%s%s%s\n" "${YELLOW}  ✓ Fish loader already sourced${NC}"
        else
            {
                echo ""
                echo "# Copilot loader"
                echo "$loader_line"
            } >> "$FISH_CONFIG"
            printf "%s%s%s\n" "${GREEN}  ✓ Added fish loader to $FISH_CONFIG${NC}"
        fi

        printf "%s%s%s\n" "${GREEN}✅ Fish config updated. Restart fish or run: source $FISH_CONFIG${NC}"
    fi
}

# ──────────────────────────────────────────────
# Get PATH as the user's default shell sees it
# ──────────────────────────────────────────────

# ──────────────────────────────────────────────
# Get PATH from a specific shell (by sourcing its RC file)
# ──────────────────────────────────────────────

get_shell_path() {
    shell="$1"
    case "$shell" in
        bash)
            # Fresh interactive bash so .bashrc is sourced (non-interactive guard passes)
            bash -i -c 'echo "$PATH"' 2>/dev/null || echo "$PATH"
            ;;
        zsh)
            zsh -i -c 'echo "$PATH"' 2>/dev/null || echo "$PATH"
            ;;
        fish)
            fish -c 'source ~/.config/fish/config.fish 2>/dev/null; string join ":" $PATH' 2>/dev/null || echo "$PATH"
            ;;
        *)
            echo "$PATH"
            ;;
    esac
}

# ──────────────────────────────────────────────
# Check which shells are available on this system
# ──────────────────────────────────────────────

detect_available_shells() {
    AVAILABLE_SHELLS=""
    current_shell=$(basename "${SHELL:-/bin/sh}")
    # Check for common shells (bash, zsh)
    for s in bash zsh; do
        command -v "$s" >/dev/null 2>&1 && AVAILABLE_SHELLS="$AVAILABLE_SHELLS $s"
    done
    # Add fish if installed
    if $FISH_INSTALLED; then
        AVAILABLE_SHELLS="$AVAILABLE_SHELLS fish"
    fi
    # Ensure current shell is included (no duplicate if already added)
    case " $AVAILABLE_SHELLS " in
        *" $current_shell "*) ;;
        *) AVAILABLE_SHELLS="$AVAILABLE_SHELLS $current_shell" ;;
    esac
}

# ──────────────────────────────────────────────
# Show per-shell PATH detection & confirm+add
# ──────────────────────────────────────────────

show_path_status() {
    detect_available_shells
    targets="/nzk/bin /nzk/appimages /nzk/shellscripts /nzk/executables"

    echo ""
    # ── 1) Show per-shell detection for each target dir ──
    for dir in $targets; do
        printf "%s\n" "${dir}"
        for s in $AVAILABLE_SHELLS; do
            shell_path=$(get_shell_path "$s")
            case ":${shell_path}:" in
                *:"${dir}":*)
                    printf "  ${GREEN}✓${NC} %-8s detected\n" "$s"
                    ;;
                *)
                    printf "  ${RED}✗${NC} %-8s NOT detected\n" "$s"
                    ;;
            esac
        done
        echo ""
    done

    # ── 2) Ask for confirmation before adding ──
    if confirm "Add missing directories to all shell configs?"; then
        setup_shell_config

        # ── 3) Re-check and confirm ──
        echo ""
        printf "%s\n" "${GREEN}✅ Verification:${NC}"
        for dir in $targets; do
            for s in $AVAILABLE_SHELLS; do
                shell_path=$(get_shell_path "$s")
                case ":${shell_path}:" in
                    *:"${dir}":*)
                        printf "  ${GREEN}✓${NC} %-8s ${dir}\n" "$s"
                        ;;
                    *)
                        printf "  ${RED}✗${NC} %-8s ${dir} — still missing (may need manual shell reload)\n" "$s"
                        ;;
                esac
            done
        done
        echo ""
        printf "%s%s%s\n" "${GREEN}✅ Done. Run '. ~/.bashrc' or open a new terminal to apply.${NC}"
    else
        printf "%s%s%s\n" "${YELLOW}⏭️  Skipped.${NC}"
    fi
}

# ──────────────────────────────────────────────
# README
# ──────────────────────────────────────────────

create_readme() {
    model_lines=""
    first=true
    for f in "$CONFIG_DIR"/*.conf; do
        [ -f "$f" ] || continue
        slug=$(basename "$f" .conf)
        model=$(sed -n 's/^export COPILOT_MODEL=//p' "$f")
        label=$(sed -n 's/^# Provider: //p' "$f")
        default_tag=""
        if $first; then
            default_tag="  ← default"
            first=false
        fi
        model_lines="${model_lines}| \`${slug}\` | ${model} | ${label}${default_tag} |\n"
    done

    cat > /nzk/special/README.md << EOF
# Copilot Model Configuration

## Models
| Slug | Model | Provider |
|------|-------|----------|
${model_lines}

## Usage
- \`copilot\` — Run with default model
- Say *"switch to <model>"* inside copilot to change models

\`\`\`sh
# Just run copilot with the default model:
copilot
\`\`\`

## Files
- \`/nzk/special/configs/*.conf\` — One file per model
- \`/nzk/special/loader.sh\` — Config loader (auto-generated)
EOF
    printf "%s%s%s\n" "${GREEN}✅ README created.${NC}"
}

# ──────────────────────────────────────────────
# Print complete
# ──────────────────────────────────────────────

print_complete() {
    count=$(count_models)
    printf "%s\n" "${GREEN}========================================${NC}"
    printf "%s\n" "${GREEN}✅ All done!${NC}"
    printf "%s\n" "${GREEN}========================================${NC}"
    printf "%s%s%s\n" "${YELLOW}📝 Next steps:${NC}"
    if [ -n "$SHELL_CONFIG" ]; then
        printf "1. Source your shell config: %s. %s%s\n" "${GREEN}" "${SHELL_CONFIG}" "${NC}"
    else
        printf "1. Source your shell config %s(.zshrc, .bashrc, etc.)%s\n" "${GREEN}" "${NC}"
    fi
    echo "   OR open a new terminal"
    echo "2. Just run:  copilot"
    echo ""
    printf "%s%s%s%s\n" "${YELLOW}📂 " "$count" " model(s) configured:" "${NC}"
    for f in "$CONFIG_DIR"/*.conf; do
        [ -f "$f" ] || continue
        slug=$(basename "$f" .conf)
        model=$(sed -n 's/^export COPILOT_MODEL=//p' "$f")
        provider=$(sed -n 's/^# Provider: //p' "$f")
        printf "   • %s%s%s  [%s]  —  copilot --model %s\n" "${GREEN}" "$slug" "${NC}" "$provider" "$model"
    done
    echo ""
    printf "%s%s%s\n" "${RED}🔑 API keys are stored in ${CONFIG_DIR}/${NC}"
    printf "%s%s%s\n" "${RED}   Make sure to keep these files secure!${NC}"
}

# ──────────────────────────────────────────────
# Main Menu
# ──────────────────────────────────────────────

printf "\n"
printf "%s\n" "${GREEN}╔═══════════════════════════════════════╗${NC}"
printf "%s\n" "${GREEN}║     GitHub Copilot CLI Configurator    ║${NC}"
printf "%s\n" "${GREEN}╚═══════════════════════════════════════╝${NC}"
echo ""

detect_existing

echo "What do you want to do?"
echo "  1) Install copilot CLI only"
echo "  2) Add / configure models (add many, pick provider per model)"
echo "  3) Both — install CLI + configure models"
echo "  4) Update keys / provider in existing models"
echo "  5) Install caveman (terse output mode — no key changes)"
echo "  6) Add /nzk/bin, /nzk/appimage, /nzk/shellscripts, /nzk/executables to PATH (if not already)"
echo "  7) Enable offline mode (skip GitHub login, use local provider)"
echo "  8) Disable login prompt (makes copilot stop asking for login)"
echo "  9) Re-apply existing configs (fix permissions after sudo install)"
echo "  q) Quit"
echo ""

while :; do
    prompt "Enter your choice [1-9]:" choice
    case $choice in
        1) install_copilot; break ;;
        2)
            setup_api_keys
            setup_shell_config
            create_readme
            print_complete
            break
            ;;
        3)
            install_copilot
            setup_api_keys
            setup_shell_config
            create_readme
            print_complete
            break
            ;;
        4)
            update_keys_only
            create_readme
            break
            ;;
        5)
            regenerate_loader
            setup_caveman
            printf "%s%s%s\n" "${GREEN}✅ Caveman mode installed. Run: copilot${NC}"
            break
            ;;
        6)
            show_path_status
            break
            ;;
        7)
            regenerate_loader
            setup_offline
            break
            ;;
        8)
            regenerate_loader
            setup_offline
            printf "%s%s%s\n" "${GREEN}  ✓ Login prompt disabled. Copilot will no longer ask for login.${NC}"
            break
            ;;
        9)
            printf "%s%s%s\n" "${YELLOW}🔧 Re-applying configs from existing models...${NC}"
            sudo chown -R "$(whoami):$(whoami)" /nzk/special/ 2>/dev/null
            regenerate_loader
            setup_offline
            # Source into current session so it works immediately
            . "$ALIASES_FILE" 2>/dev/null || true
            printf "%s%s%s\n" "${GREEN}  ✓ Configs re-applied using existing models.${NC}"
            printf "%s%s%s\n" "${YELLOW}  ➜ Run: source /nzk/special/aliases.sh  (if env vars not yet loaded)${NC}"
            break
            ;;
        q|Q) printf "Bye.\n"; exit 0 ;;
        *) printf "  Invalid choice.\n" ;;
    esac
done

# ── Apply configs for additional users (--users flag) ──
if [ -n "$ADDITIONAL_USERS" ]; then
    echo ""
    printf "%s%s%s\n" "${YELLOW}👥 Applying configs for additional users: ${ADDITIONAL_USERS}${NC}"
    old_ifs="$IFS"
    IFS=","
    for u in $ADDITIONAL_USERS; do
        apply_for_user "$u"
    done
    IFS="$old_ifs"
fi
