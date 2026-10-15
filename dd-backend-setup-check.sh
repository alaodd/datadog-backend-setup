#!/usr/bin/env bash
#
# dd-backend-setup-check.sh
#
# Audits a Datadog macOS laptop against the backend-track setup instructions:
# the dual-identity/signing gate, laptop-setup.sh, GitLab access via ddtool,
# Doggo, and the dd-source repo (Bazel, dd-doctor, rapid, Gazelle).
#
# BACKEND TRACK ONLY. If you are frontend-only, skip this entirely — the
# frontend track is fully self-contained and does not need laptop-setup.sh.
# Use dd-frontend-setup-check.sh instead.
#
# For every item the script prints one of:
#   [OK]        already installed / already configured  -> nothing to do
#   [INSTALLED] was missing, this script installed it
#   [FAILED]    was missing, install was attempted and failed
#   [MANUAL]    cannot be automated (GUI app, Chrome extension, interactive login)
#   [SKIPPED]   skipped by you or by --check-only / --dry-run
#   [WARN]      present but not in the state the instructions expect
#
# Usage:
#   ./dd-backend-setup-check.sh                   # audit, then prompt before each change
#   ./dd-backend-setup-check.sh --check-only      # audit only, change nothing
#   ./dd-backend-setup-check.sh --dry-run         # audit, print the commands, run nothing
#   ./dd-backend-setup-check.sh --yes             # apply fixes without prompting
#   ./dd-backend-setup-check.sh --no-network      # skip every check that hits the network
#   ./dd-backend-setup-check.sh --run-laptop-setup
#                                                 # also RUN laptop-setup.sh. Not implied by
#                                                 # --yes: it takes hours, wants sudo several
#                                                 # times, and can pull tens of GB.
#   ./dd-backend-setup-check.sh --skip-doctor     # do not run `bzl run //:dd-doctor`
#   ./dd-backend-setup-check.sh --doctor-timeout 1800
#                                                 # seconds allowed for dd-doctor (default 900)
#   ./dd-backend-setup-check.sh --email first.last@datadoghq.com
#
# Safe to re-run. laptop-setup.sh itself is also safe to Ctrl-C and re-run.

set -uo pipefail

# ---------------------------------------------------------------------------
# Configuration / flags
# ---------------------------------------------------------------------------

ASSUME_YES=0
CHECK_ONLY=0
DRY_RUN=0
NO_NETWORK=0
RUN_LAPTOP_SETUP=0
SKIP_DOCTOR=0
DOCTOR_TIMEOUT=900
DD_EMAIL=""

GIT_CONFIG_TOOL_MIN="3.0.0"
GCT_DOCTOR_EXPECTED=27
GCT_TOOL_TOML="$HOME/.config/datadog/git/tool.toml"
GIT_CONFIG_TOOL_INSTALL="curl -fsSL https://binaries.ddbuild.io/devtools/apps/git-config-tool/install.sh | sh"

LAPTOP_SETUP_URL="https://github.com/DataDog/devtools/raw/master/laptop-ansible/laptop-setup.sh"
LAPTOP_SETUP_PATH="$HOME/laptop-setup.sh"
LAPTOP_SETUP_WORST_CASE="a few hours, ~32GB"

DDTOOL_MIN="1.87.0"
GITLAB_HOST="gitlab.ddbuild.io"

# dd-source moved org on 2026-06-25. Unlike web-ui — whose local path keeps
# saying DataDog — the dd-source path DOES use ddoghq. Do not normalise either
# one to match the other; both are documented as written.
DD_SOURCE_CANONICAL="$HOME/go/src/github.com/ddoghq/dd-source"
DD_SOURCE_LEGACY="$HOME/go/src/github.com/DataDog/dd-source"
DD_SOURCE_REPO="ddoghq/dd-source"
DD_SOURCE_FROZEN_REPO="DataDog/dd-source"
DD_SOURCE_MIGRATED_ON="2026-06-25"
DD_SOURCE_SLACK="#dd-source"
DD_DOCTOR_TARGET="//:dd-doctor"
DOGGO_EXT_ID="hcdoigpbdkefpiejgenmfgkfglmhacbk"
INTERNAL_HOSTS="binaries.ddbuild.io gitlab.ddbuild.io"
GO_MODULE_PATH_TICKET="LANGTOOLS-4580"

usage() {
  sed -n '/^# Usage:/,/^# Safe to re-run/p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
}

while [ $# -gt 0 ]; do
  case "$1" in
    -y|--yes)            ASSUME_YES=1 ;;
    -c|--check-only)     CHECK_ONLY=1 ;;
    -n|--dry-run)        DRY_RUN=1 ;;
    --no-network)        NO_NETWORK=1 ;;
    --run-laptop-setup)  RUN_LAPTOP_SETUP=1 ;;
    --skip-doctor)       SKIP_DOCTOR=1 ;;
    --doctor-timeout)    DOCTOR_TIMEOUT="${2:-900}"; shift ;;
    --email)             DD_EMAIL="${2:-}"; shift ;;
    -h|--help)           usage ;;
    *) echo "Unknown option: $1 (try --help)" >&2; exit 2 ;;
  esac
  shift
done

# ---------------------------------------------------------------------------
# Output plumbing
# ---------------------------------------------------------------------------

LOG_FILE="${HOME}/dd-backend-setup-check-$(date +%Y%m%d-%H%M%S).log"

if [ -t 1 ]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
  C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'
  C_BLUE=$'\033[34m'; C_CYAN=$'\033[36m'; C_MAGENTA=$'\033[35m'
else
  C_RESET=""; C_BOLD=""; C_DIM=""
  C_GREEN=""; C_YELLOW=""; C_RED=""; C_BLUE=""; C_CYAN=""; C_MAGENTA=""
fi

: > "$LOG_FILE"

emit() {
  printf '%s\n' "$1"
  printf '%s\n' "$1" | sed -E $'s/\033\\[[0-9;]*m//g' >> "$LOG_FILE"
}

N_OK=0; N_INSTALLED=0; N_FAILED=0; N_MANUAL=0; N_SKIPPED=0; N_WARN=0
RESULTS=()

record() {
  RESULTS+=("$1|$2|$3")
  case "$1" in
    OK)        N_OK=$((N_OK+1)) ;;
    INSTALLED) N_INSTALLED=$((N_INSTALLED+1)) ;;
    FAILED)    N_FAILED=$((N_FAILED+1)) ;;
    MANUAL)    N_MANUAL=$((N_MANUAL+1)) ;;
    SKIPPED)   N_SKIPPED=$((N_SKIPPED+1)) ;;
    WARN)      N_WARN=$((N_WARN+1)) ;;
  esac
}

ok()        { emit "  ${C_GREEN}[OK]${C_RESET}        $1 — ${C_DIM}already installed${C_RESET}${2:+ ($2)}"; record OK "$1" "${2:-already installed}"; }
ok_cfg()    { emit "  ${C_GREEN}[OK]${C_RESET}        $1 — ${C_DIM}already configured${C_RESET}${2:+ ($2)}"; record OK "$1" "${2:-already configured}"; }
installed() { emit "  ${C_CYAN}[INSTALLED]${C_RESET} $1${2:+ — $2}"; record INSTALLED "$1" "${2:-installed by this script}"; }
failed()    { emit "  ${C_RED}[FAILED]${C_RESET}    $1${2:+ — $2}"; record FAILED "$1" "${2:-install failed}"; }
manual()    { emit "  ${C_MAGENTA}[MANUAL]${C_RESET}    $1${2:+ — $2}"; record MANUAL "$1" "${2:-needs a human}"; }
skipped()   { emit "  ${C_YELLOW}[SKIPPED]${C_RESET}   $1${2:+ — $2}"; record SKIPPED "$1" "${2:-skipped}"; }
warn()      { emit "  ${C_YELLOW}[WARN]${C_RESET}      $1${2:+ — $2}"; record WARN "$1" "${2:-unexpected state}"; }
info()      { emit "              ${C_DIM}$1${C_RESET}"; }
hdr()       { emit ""; emit "${C_BOLD}${C_BLUE}=== $1 ===${C_RESET}"; }
checking()  { emit "  ${C_DIM}checking:${C_RESET} $1"; }

have() { command -v "$1" >/dev/null 2>&1; }

# A download that "succeeded" is not the same as a usable script. DataDog/devtools
# is private, so the documented `curl -Lo ... github.com/.../raw/...` quietly saves
# a login/SSO HTML page when unauthenticated — a large, non-empty file that is not
# a shell script at all. Check the shebang and reject HTML explicitly.
valid_shell_script() { # valid_shell_script <path>
  [ -s "$1" ] || return 1
  local first
  IFS= read -r first < "$1" 2>/dev/null || return 1
  case "$first" in \#!*) ;; *) return 1 ;; esac
  if head -c 4096 "$1" 2>/dev/null | grep -qiE '<!doctype html|<html[ >]'; then
    return 1
  fi
  return 0
}

# `stat` is not portable here. macOS ships BSD stat, where -f is a format
# string, but Homebrew coreutils puts a GNU stat on PATH where -f means
# "file system status" and the same call prints filesystem info instead of a
# mode. Prefer the absolute BSD path, then fall back to the GNU spelling.
file_mode() { # file_mode <path> -> octal mode, empty when it cannot be read
  local m
  m="$(/usr/bin/stat -f '%OLp' "$1" 2>/dev/null)"
  if [ -n "$m" ]; then printf '%s' "$m"; return 0; fi
  m="$(stat -c '%a' "$1" 2>/dev/null)"
  if [ -n "$m" ]; then printf '%s' "$m"; return 0; fi
  return 1
}

run_timeout() {
  local secs="$1"; shift
  "$@" & local pid=$!
  ( sleep "$secs"; kill -9 "$pid" 2>/dev/null ) & local watcher=$!
  wait "$pid" 2>/dev/null; local rc=$?
  kill -9 "$watcher" 2>/dev/null; wait "$watcher" 2>/dev/null
  return $rc
}

confirm() {
  [ "$ASSUME_YES" -eq 1 ] && return 0
  [ ! -t 0 ] && return 1
  local reply=""
  printf '  %s[?]%s %s [y/N] ' "$C_YELLOW" "$C_RESET" "$1"
  read -r reply
  printf '  [?] %s -> %s\n' "$1" "${reply:-N}" >> "$LOG_FILE"
  case "$reply" in [yY]|[yY][eE][sS]) return 0 ;; *) return 1 ;; esac
}

install_step() {
  local item="$1" cmd="$2"
  info "command: $cmd"
  if [ "$CHECK_ONLY" -eq 1 ]; then
    skipped "$item" "not applied (--check-only)"; return 1
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    skipped "$item" "would run: $cmd (--dry-run)"; return 1
  fi
  if ! confirm "Run this for $item?"; then
    skipped "$item" "declined at prompt"; return 1
  fi
  emit "  ${C_DIM}running:${C_RESET} $cmd"
  if bash -c "$cmd" 2>&1 | tee -a "$LOG_FILE"; then
    return 0
  fi
  return 1
}

version_ge() {
  [ "$(printf '%s\n%s\n' "$2" "$1" | sort -t. -k1,1n -k2,2n -k3,3n | head -1)" = "$2" ]
}

# Interactive commands must own the terminal. install_step pipes through tee so
# it can log output, but that makes stdout a pipe and breaks prompts and
# browser-handoff flows. Run these attached instead, and record only the
# invocation and exit status in the log.
# `git config-tool setup` manages commit-signing keys through whichever account
# gh has ACTIVE, and that needs the admin:ssh_signing_key scope. With a personal
# and a work account both logged in, the active one is easily the wrong one —
# and the tool's own advice ("gh auth refresh --scopes admin:ssh_signing_key")
# would grant that scope to the personal account and sign under it. Prefer
# switching accounts over widening scopes.
gh_accounts_table() { # -> "<login>|<active 0|1>|<scopes>" per account
  run_timeout 40 gh auth status 2>&1 | awk '
    /Logged in to .* account / {
      if (acct != "") print acct "|" active "|" scopes
      acct=$0; sub(/.*account /,"",acct); sub(/ .*/,"",acct); active=0; scopes=""
    }
    /Active account: true/ { active=1 }
    /Token scopes:/        { s=$0; sub(/.*Token scopes: /,"",s); scopes=s }
    END { if (acct != "") print acct "|" active "|" scopes }
  '
}

# 0 when the active gh account can manage signing keys (after an offered switch
# if needed); 1 when it cannot and setup would fail the same way again.
ensure_gh_signing_account() {
  have gh || { info "gh is not installed; cannot verify which accounts setup will use."; return 0; }
  local table n internal public missing_scope
  table="$(gh_accounts_table)"
  [ -z "$table" ] && { warn "gh signing accounts" "no gh accounts logged in"; return 1; }

  n="$(printf '%s\n' "$table" | grep -c .)"
  internal="$(printf '%s\n' "$table" | awk -F'|' '$1 ~ /_ddog$/ {print $1}' | head -1)"
  public="$(printf '%s\n' "$table" | awk -F'|' '$1 !~ /_ddog$/ {print $1}' | head -1)"
  printf '%s\n' "$table" | while IFS='|' read -r acct act sc; do
    case "$sc" in *admin:ssh_signing_key*) info "$acct: has admin:ssh_signing_key" ;;
                  *) info "$acct: MISSING admin:ssh_signing_key" ;; esac
  done

  # The tool manages two identities on purpose: DataDog-org repos through your
  # public account, ddoghq internal repos through the *_ddog one. It refuses to
  # run with anything other than exactly those two.
  if [ "$n" -ne 2 ] || [ -z "$internal" ] || [ -z "$public" ]; then
    warn "gh signing accounts" "setup needs exactly two accounts — one public and one ending in _ddog; found $n (${internal:-no _ddog account}${public:+, public: $public})"
    if [ -z "$internal" ]; then
      info "Sign in to your internal account: gh auth login --skip-ssh-key --web -p ssh --scopes=admin:ssh_signing_key"
    fi
    if [ -z "$public" ]; then
      info "Sign in to your PUBLIC Datadog account (the one 'ssh -T git@github.com' reports), not an unrelated personal one:"
      info "  gh auth login --skip-ssh-key --web -p ssh --scopes=admin:ssh_signing_key"
      local ssh_who
      ssh_who="$(run_timeout 20 ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -T git@github.com 2>&1 | sed -n 's/^Hi \([^!]*\)!.*/\1/p' | head -1)"
      [ -n "$ssh_who" ] && info "  github.com SSH authenticates as '$ssh_who' — that is the public account to use."
    fi
    if [ "$n" -gt 2 ]; then
      info "Remove any unrelated account: gh auth logout --hostname github.com --user <login>"
    fi
    return 1
  fi

  # Both accounts need the scope; gh auth refresh only applies to the active one.
  missing_scope="$(printf '%s\n' "$table" | awk -F'|' '$3 !~ /admin:ssh_signing_key/ {print $1}')"
  if [ -n "$missing_scope" ]; then
    warn "gh signing accounts" "missing admin:ssh_signing_key on: $(printf '%s' "$missing_scope" | tr '\n' ' ')"
    info "gh auth refresh only applies to the active account, so switch to each one first:"
    printf '%s\n' "$missing_scope" | while IFS= read -r acct; do
      [ -n "$acct" ] && info "  gh auth switch --hostname github.com --user $acct && gh auth refresh --hostname github.com --scopes admin:ssh_signing_key"
    done
    return 1
  fi

  ok_cfg "gh signing accounts" "public '$public' and internal '$internal', both with admin:ssh_signing_key"
  return 0
}

install_step_interactive() {
  local item="$1" cmd="$2"
  info "command: $cmd"
  info "(interactive — it takes over this terminal and prompts you directly)"
  if [ "$CHECK_ONLY" -eq 1 ]; then
    skipped "$item" "not applied (--check-only)"; return 1
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    skipped "$item" "would run: $cmd (--dry-run)"; return 1
  fi
  if [ ! -t 0 ]; then
    skipped "$item" "needs an interactive terminal — run it yourself: $cmd"; return 1
  fi
  if ! confirm "Run $item now? It will prompt you directly."; then
    skipped "$item" "declined at prompt"; return 1
  fi
  emit "  ${C_DIM}running (interactive):${C_RESET} $cmd"
  printf '  [interactive] %s\n' "$cmd" >> "$LOG_FILE"
  # Run attached so prompts and browser handoff work. The cost is that output
  # goes to the terminal rather than the log, so the exit status is all we can
  # record here — which makes reporting it non-negotiable.
  bash -c "$cmd"
  local rc=$?
  printf '  [interactive] exit %d\n' "$rc" >> "$LOG_FILE"
  if [ "$rc" -ne 0 ]; then
    failed "$item" "command exited $rc — its output went to your terminal, not the log"
    info "To capture the output for diagnosis, re-run it under script:"
    info "  script -q /tmp/${item// /-}.log $cmd"
  fi
  return $rc
}

# Whether `git config-tool doctor` is actually running the commit-signing
# checks. They are optional, gated on manage-signing in tool.toml, so a passing
# doctor without them says nothing about signing at all.
gct_signing_enabled() {
  grep -qE '^[[:space:]]*manage-signing[[:space:]]*=[[:space:]]*true' "$GCT_TOOL_TOML" 2>/dev/null && return 0
  # Fall back to the output itself: the tool advertises the switch when it is off.
  printf '%s' "${gct_out:-}" | grep -qi 'manage-signing' && return 1
  printf '%s' "${gct_out:-}" | grep -qiE 'signing|signingKey' && return 0
  return 1
}

login_zsh() { # login_zsh '<zsh expression to print>'
  have zsh || return 1
  # A login shell may print banners before our value: Apple Terminal's
  # "Restored session: ...", an MOTD, plugin chatter. Fence the value between
  # sentinels and keep only what lands between them, so nothing the shell says
  # on the way in can contaminate the result.
  local out
  out="$(run_timeout 25 env SHELL_SESSIONS_DISABLE=1 zsh -lic \
    "printf '<<<DD_VAL_START>>>%s<<<DD_VAL_END>>>' \"$1\"" 2>/dev/null)"
  printf '%s' "$out" | tr -d '\n' \
    | sed -n 's/.*<<<DD_VAL_START>>>\(.*\)<<<DD_VAL_END>>>.*/\1/p'
}

# ---------------------------------------------------------------------------
# Header
# ---------------------------------------------------------------------------

emit "${C_BOLD}Datadog backend track setup — installed-state check${C_RESET}"
emit "${C_DIM}Log:  ${LOG_FILE}${C_RESET}"
emit "${C_DIM}Host: $(scutil --get ComputerName 2>/dev/null || hostname) | macOS $(sw_vers -productVersion 2>/dev/null) | $(uname -m)${C_RESET}"
mode_desc="apply fixes (prompting)"
[ "$ASSUME_YES" -eq 1 ] && mode_desc="apply fixes (no prompts)"
[ "$DRY_RUN" -eq 1 ]    && mode_desc="dry run — report only, print commands"
[ "$CHECK_ONLY" -eq 1 ] && mode_desc="check only — report, change nothing"
emit "${C_DIM}Mode: ${mode_desc}${C_RESET}"
emit ""
emit "  ${C_MAGENTA}Backend track only.${C_RESET} ${C_DIM}Frontend-only contributors should skip this entirely —"
emit "  that track is self-contained and does not need laptop-setup.sh. Use dd-frontend-setup-check.sh.${C_RESET}"

if [ -z "$DD_EMAIL" ]; then
  _ge="$(git config --global user.email 2>/dev/null || true)"
  case "$_ge" in *@datadoghq.com) DD_EMAIL="$_ge" ;; esac
fi

# ---------------------------------------------------------------------------
# Step 1 — Gate: dual identity and commit signing
# ---------------------------------------------------------------------------

hdr "Step 1 — Gate: dual identity and signing (git config-tool doctor)"

info "This gate comes first. Do not run laptop-setup.sh until every doctor check passes WITH commit-signing checks enabled."
info "The instructions quote $GCT_DOCTOR_EXPECTED/$GCT_DOCTOR_EXPECTED; the total varies by tool version, so the condition checked here is all-pass plus signing enabled."

checking "git config-tool"
gct=""
if have git-config-tool; then
  gct="$(command -v git-config-tool)"
elif [ -x "$HOME/.local/bin/git-config-tool" ]; then
  gct="$HOME/.local/bin/git-config-tool"
  info "found at $gct but not on PATH — add ~/.local/bin to PATH in ~/.zshrc"
fi

if [ -n "$gct" ]; then
  ok "git config-tool" "$gct"
else
  if install_step "git config-tool" "$GIT_CONFIG_TOOL_INSTALL"; then
    if have git-config-tool; then gct="$(command -v git-config-tool)"
    elif [ -x "$HOME/.local/bin/git-config-tool" ]; then gct="$HOME/.local/bin/git-config-tool"; fi
    [ -n "$gct" ] && installed "git config-tool" "$gct" \
                  || failed "git config-tool" "installer ran but the binary was not found"
  fi
fi

gate_ok=1
if [ -n "$gct" ]; then
  checking "git config-tool version >= $GIT_CONFIG_TOOL_MIN"
  gct_version="$(run_timeout 30 "$gct" version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
  if [ -z "$gct_version" ]; then
    warn "git config-tool version" "could not determine the version"
  elif version_ge "$gct_version" "$GIT_CONFIG_TOOL_MIN"; then
    ok_cfg "git config-tool version" "$gct_version"
  else
    warn "git config-tool version" "$gct_version is older than $GIT_CONFIG_TOOL_MIN"
    if install_step "git config-tool upgrade" "$GIT_CONFIG_TOOL_INSTALL"; then
      installed "git config-tool upgrade" "re-run this script to re-check"
    fi
  fi

  if [ "$NO_NETWORK" -eq 1 ]; then
    skipped "git config-tool doctor" "--no-network"
  else
    checking "git config-tool doctor"
    gct_out="$(run_timeout 90 "$gct" doctor 2>&1)"
    gct_rc=$?
    printf '%s\n' "$gct_out" >> "$LOG_FILE"
    gct_score="$(printf '%s' "$gct_out" | grep -oE '[0-9]+/[0-9]+ checks passed' | head -1 | awk '{print $1}')"
    gct_passed="${gct_score%%/*}"
    gct_total="${gct_score##*/}"
    [ -n "${gct_score:-}" ] && info "doctor reports $gct_score checks passed"

    if [ $gct_rc -ne 0 ]; then
      warn "git config-tool doctor" "exit $gct_rc${gct_score:+ ($gct_score)} — fix before running laptop-setup.sh"
      printf '%s' "$gct_out" | tail -20 | while IFS= read -r line; do info "$line"; done
      if ensure_gh_signing_account && install_step_interactive "git config-tool setup" "$gct setup"; then
        installed "git config-tool setup" "completed — re-run this script to re-score doctor"
      fi
    elif [ -z "${gct_score:-}" ]; then
      ok_cfg "git config-tool doctor" "passed, but the N/M score could not be parsed"
      gate_ok=0
    elif [ "$gct_passed" != "$gct_total" ]; then
      warn "git config-tool doctor" "$gct_score — not every check passes"
      if ensure_gh_signing_account && install_step_interactive "git config-tool setup" "$gct setup"; then
        installed "git config-tool setup" "completed — re-run this script to re-score doctor"
      fi
    elif ! gct_signing_enabled; then
      # All checks pass, but the commit-signing checks are not among them, so a
      # green doctor says nothing at all about signing. The documented gate is
      # "27/27", but the total varies by tool version — what actually matters is
      # that signing is being verified and everything passes.
      warn "git config-tool doctor" "$gct_score — all pass, but commit-signing checks are not running"
      info "Signing is mandatory. A green doctor without them tells you nothing about it."
      if [ -f "$GCT_TOOL_TOML" ]; then
        info "Enable them: set manage-signing = true in $GCT_TOOL_TOML, then run: $gct setup"
        if grep -qE '^[[:space:]]*manage-signing[[:space:]]*=[[:space:]]*false' "$GCT_TOOL_TOML" \
           && install_step "enable commit-signing checks" \
              "sed -i '' -E 's/^([[:space:]]*manage-signing[[:space:]]*=[[:space:]]*)false/\\1true/' \"$GCT_TOOL_TOML\" && $gct setup"; then
          installed "enable commit-signing checks" "manage-signing = true, then re-ran setup — re-run this script to re-score doctor"
        fi
      fi
    else
      ok_cfg "git config-tool doctor" "$gct_score, with commit-signing checks enabled"
      if [ -n "${gct_total:-}" ] && [ "$gct_total" -ne "$GCT_DOCTOR_EXPECTED" ] 2>/dev/null; then
        info "The instructions quote $GCT_DOCTOR_EXPECTED/$GCT_DOCTOR_EXPECTED; this tool version runs $gct_total checks. Everything passing with signing enabled is the condition that matters."
      fi
      gate_ok=0
    fi
  fi
fi

# ---------------------------------------------------------------------------
# Step 2 — laptop-setup.sh
# ---------------------------------------------------------------------------

hdr "Step 2 — laptop-setup.sh"

# The known gotcha: laptop-setup.sh edits ~/.zshrc, and on some new laptops the
# file's permissions block writes entirely (ls -la shows ----------). Check this
# BEFORE running the script, not after wondering why env vars never appeared.
checking "~/.zshrc is writable (laptop-setup.sh edits it)"
if [ ! -e "$HOME/.zshrc" ]; then
  warn "~/.zshrc" "does not exist — create it: touch ~/.zshrc"
else
  zmode="$(file_mode "$HOME/.zshrc")"
  zperm="$(ls -la "$HOME/.zshrc" | awk '{print $1}')"
  info "mode $zmode ($zperm)"
  if [ -w "$HOME/.zshrc" ]; then
    ok_cfg "~/.zshrc writable" "mode $zmode"
  else
    warn "~/.zshrc writable" "mode $zmode blocks writes — laptop-setup.sh cannot add your env vars"
    if install_step "~/.zshrc permission fix" "chmod 600 \"$HOME/.zshrc\""; then
      installed "~/.zshrc permission fix" "now mode $(file_mode "$HOME/.zshrc")"
    fi
  fi
fi

checking "laptop-setup.sh available and valid"
# devtools is already cloned by the setup itself, and its copy is authoritative,
# so prefer it over anything downloaded.
_root="${DATADOG_ROOT:-$HOME/dd}"
LAPTOP_SETUP_PATH=""
_bad_candidates=""
for _cand in "$_root/devtools/laptop-ansible/laptop-setup.sh" \
             "$HOME/Downloads/laptop-setup.sh" \
             "$HOME/laptop-setup.sh"; do
  [ -e "$_cand" ] || continue
  if valid_shell_script "$_cand"; then
    [ -z "$LAPTOP_SETUP_PATH" ] && LAPTOP_SETUP_PATH="$_cand" && continue
  else
    _bad_candidates="${_bad_candidates} $_cand"
  fi
done

if [ -n "$LAPTOP_SETUP_PATH" ]; then
  ok "laptop-setup.sh" "$LAPTOP_SETUP_PATH ($(wc -c < "$LAPTOP_SETUP_PATH" | tr -d ' ') bytes)"
  case "$LAPTOP_SETUP_PATH" in
    "$_root"/devtools/*) info "Using the devtools clone's own copy — no download needed." ;;
  esac
elif [ "$NO_NETWORK" -eq 1 ]; then
  skipped "laptop-setup.sh" "--no-network and no valid local copy"
else
  warn "laptop-setup.sh" "no valid copy found"
  info "Source it from the devtools clone if you have one: $_root/devtools/laptop-ansible/laptop-setup.sh"
  info "Otherwise download it while signed in to GitHub in a browser — devtools is private, so a plain curl returns a login page."
fi

# Call out any file that is present but is not actually a script. Executing one
# of these would feed HTML to bash.
for _bad in $_bad_candidates; do
  _kind="$(file -b "$_bad" 2>/dev/null | cut -c1-40)"
  warn "laptop-setup.sh (invalid copy)" "$_bad is not a shell script — $_kind"
  info "This is what an unauthenticated 'curl -Lo' against a private repo produces."
  if install_step "remove invalid laptop-setup.sh" "rm -f \"$_bad\""; then
    installed "remove invalid laptop-setup.sh" "deleted $_bad"
  fi
done

checking "laptop-setup.sh run"
if [ ! -s "$LAPTOP_SETUP_PATH" ]; then
  skipped "laptop-setup.sh run" "no script to run"
elif [ "$gate_ok" -ne 0 ]; then
  skipped "laptop-setup.sh run" "the signing gate in Step 1 is not green — fix it first"
elif [ "$RUN_LAPTOP_SETUP" -ne 1 ]; then
  manual "laptop-setup.sh run" "not run by default — re-run with --run-laptop-setup, or run it yourself: /bin/bash $LAPTOP_SETUP_PATH"
  info "Worst case $LAPTOP_SETUP_WORST_CASE. Accept the default prompts with Enter; it asks for sudo a few times."
  info "Safe to Ctrl-C and re-run. Watch progress in another terminal with: du -csh ~/dd/*"
else
  info "Worst case $LAPTOP_SETUP_WORST_CASE. Accept defaults with Enter; it asks for sudo a few times."
  info "Safe to Ctrl-C and re-run. Watch progress elsewhere with: du -csh ~/dd/*"
  if install_step "laptop-setup.sh run" "/bin/bash \"$LAPTOP_SETUP_PATH\""; then
    installed "laptop-setup.sh run" "completed"
  fi
fi

# Whether the script's env vars actually landed is the real post-run check, and
# it is also how the ~/.zshrc permission gotcha shows itself.
if have zsh; then
  checking "env vars from laptop-setup.sh present in a new shell"
  eff_root="$(login_zsh '${DATADOG_ROOT}')"
  if [ -n "$eff_root" ]; then
    ok_cfg "DATADOG_ROOT" "$eff_root"
  else
    warn "DATADOG_ROOT" "not set in a new login shell"
    info "If laptop-setup.sh has already run, this is the ~/.zshrc permission gotcha: chmod 600 ~/.zshrc, then 'exec zsh'."
  fi
fi

dd_root="${eff_root:-$HOME/dd}"
checking "\$DATADOG_ROOT populated"
if [ -d "$dd_root" ]; then
  ok_cfg "DATADOG_ROOT contents" "$dd_root ($(du -csh "$dd_root" 2>/dev/null | tail -1 | awk '{print $1}') on disk)"
else
  warn "DATADOG_ROOT contents" "$dd_root does not exist yet"
fi

# ---------------------------------------------------------------------------
# Step 3 — GitLab access (CI/CD)
# ---------------------------------------------------------------------------

hdr "Step 3 — GitLab access for CI/CD (ddtool short-lived tokens)"

checking "ddtool >= v$DDTOOL_MIN"
if ! have ddtool; then
  if have brew; then
    if install_step "ddtool" "brew update && brew install ddtool"; then
      have ddtool && installed "ddtool" "$(run_timeout 25 ddtool version 2>/dev/null | head -1)" \
                  || failed "ddtool" "brew install ran but ddtool is not on PATH"
    fi
  else
    failed "ddtool" "missing and Homebrew is unavailable"
  fi
else
  ddtool_ver="$(run_timeout 25 ddtool version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
  if [ -z "$ddtool_ver" ]; then
    warn "ddtool version" "could not determine the version"
  elif version_ge "$ddtool_ver" "$DDTOOL_MIN"; then
    ok "ddtool" "v$ddtool_ver"
  else
    warn "ddtool" "v$ddtool_ver is older than the required v$DDTOOL_MIN"
    if have brew && install_step "ddtool upgrade" "brew update && brew upgrade ddtool"; then
      installed "ddtool upgrade" "now $(run_timeout 25 ddtool version 2>/dev/null | head -1)"
    fi
  fi
fi

if ! have ddtool; then
  skipped "GitLab token" "ddtool unavailable"
elif [ "$NO_NETWORK" -eq 1 ]; then
  skipped "GitLab token" "--no-network"
else
  checking "GitLab short-lived token (ddtool auth gitlab token)"
  # Exits 0 with empty output when not logged in, so this never opens a browser
  # or blocks on a prompt.
  gl_token="$(run_timeout 25 ddtool auth gitlab token </dev/null 2>>"$LOG_FILE" | tr -d '[:space:]')"
  if [ -z "$gl_token" ]; then
    warn "GitLab token" "not logged in"
    if install_step_interactive "GitLab login" "ddtool auth gitlab login"; then
      installed "GitLab login" "completed — re-run this script to verify the token"
    fi
    skipped "GitLab API sanity check" "no token to test with"
  else
    ok_cfg "GitLab token" "token issued (valid ~2 hours; call 'ddtool auth gitlab token' again when it expires)"
    checking "GitLab API sanity check (/api/v4/user)"
    gl_user="$(run_timeout 25 curl -s --max-time 20 --header "Authorization: Bearer $gl_token" \
      "https://${GITLAB_HOST}/api/v4/user" 2>/dev/null)"
    printf 'gitlab /api/v4/user: %s\n' "$gl_user" >> "$LOG_FILE"
    gl_username="$(printf '%s' "$gl_user" | sed -n 's/.*"username":"\([^"]*\)".*/\1/p' | head -1)"
    if [ -n "$gl_username" ]; then
      ok_cfg "GitLab API sanity check" "authenticated as '$gl_username'"
    else
      warn "GitLab API sanity check" "token did not authenticate against $GITLAB_HOST"
    fi
  fi
fi

# The legacy Personal Access Token + Keychain flow still works but is being
# deprecated. Flag it if present; never set it up fresh.
checking "legacy Personal Access Token flow not in use"
legacy_pat=""
security find-generic-password -a "${USER:-$(whoami)}" -s gitlab_token -w >/dev/null 2>&1 && legacy_pat="keychain"
grep -q 'GITLAB_TOKEN' "$HOME/.zshrc" 2>/dev/null && legacy_pat="${legacy_pat:+$legacy_pat, }~/.zshrc"
if [ -z "$legacy_pat" ]; then
  ok_cfg "Legacy PAT flow" "not in use — you are on the preferred short-lived token flow"
else
  warn "Legacy PAT flow" "found traces in: $legacy_pat — this flow is being deprecated"
  info "Keep it if it still works for you, but new setups should use 'ddtool auth gitlab login' only."
fi

# ---------------------------------------------------------------------------
# Step 4 — Doggo
# ---------------------------------------------------------------------------

hdr "Step 4 — Doggo Chrome extension"

info "Same step as the frontend track — only needed once, whichever track you are on."

checking "Doggo Chrome extension (id $DOGGO_EXT_ID)"
doggo_found=0
for prof in "$HOME/Library/Application Support/Google/Chrome"/*/Extensions; do
  [ -d "$prof/$DOGGO_EXT_ID" ] && doggo_found=1 && break
done
if [ "$doggo_found" -eq 1 ]; then
  ok "Doggo Chrome extension" "installed in a Chrome profile"
else
  manual "Doggo Chrome extension" "install from https://chromewebstore.google.com/detail/doggo-datadog-companion/$DOGGO_EXT_ID"
fi

# ---------------------------------------------------------------------------
# Step 5 — dd-source
# ---------------------------------------------------------------------------

hdr "Step 5 — dd-source"

info "Canonical docs are the two Confluence pages (space FF): 'Getting Started with dd-source'"
info "and the 'dd-source -> ddoghq' migration FAQ. There is no CONTRIBUTING.md or DEVELOPING.md"
info "at the repo root, and domains/onboarding/ is a customer-facing product, not a dev-setup doc."
manual "Slack $DD_SOURCE_SLACK" "join the channel and read 'Getting Started with dd-source' (space FF)"

checking "dd-source checkout"
dd_source=""
dd_source_other=""
if [ -d "$DD_SOURCE_CANONICAL/.git" ]; then
  dd_source="$DD_SOURCE_CANONICAL"
else
  for cand in "$DD_SOURCE_LEGACY" "$dd_root/dd-source" "$HOME/dd/dd-source"; do
    if [ -d "$cand/.git" ]; then dd_source_other="$cand"; break; fi
  done
fi

dd_source_any="${dd_source:-$dd_source_other}"

if [ -n "$dd_source" ]; then
  ok_cfg "dd-source checkout" "$dd_source"
  info "Note the path uses ddoghq. web-ui is the opposite — its local path keeps saying DataDog. Both are correct as written."
elif [ -n "$dd_source_other" ]; then
  warn "dd-source checkout" "found at $dd_source_other, not the documented $DD_SOURCE_CANONICAL"
  info "The documented path is $DD_SOURCE_CANONICAL (ddoghq in the path, unlike web-ui)."
  if [ -e "$DD_SOURCE_CANONICAL" ]; then
    warn "dd-source move" "$DD_SOURCE_CANONICAL already exists — not touching either copy"
  else
    info "Moving it is just a directory move as far as git is concerned, but Bazel caches"
    info "absolute paths, so expect the next build to be cold. Commit or stash first."
    if install_step "dd-source move" "mkdir -p \"$(dirname "$DD_SOURCE_CANONICAL")\" && mv \"$dd_source_other\" \"$DD_SOURCE_CANONICAL\""; then
      if [ -d "$DD_SOURCE_CANONICAL/.git" ]; then
        installed "dd-source move" "moved to $DD_SOURCE_CANONICAL"
        dd_source="$DD_SOURCE_CANONICAL"; dd_source_other=""; dd_source_any="$DD_SOURCE_CANONICAL"
      else
        failed "dd-source move" "move ran but no git repo at $DD_SOURCE_CANONICAL"
      fi
    fi
  fi
else
  warn "dd-source checkout" "not found — clone $DD_SOURCE_REPO to $DD_SOURCE_CANONICAL"
fi

# Org check: DataDog/dd-source is frozen as of the migration.
if [ -n "$dd_source_any" ]; then
  checking "dd-source remote points at $DD_SOURCE_REPO"
  ds_remote="$(git -C "$dd_source_any" remote get-url origin 2>/dev/null)"
  info "origin: ${ds_remote:-unknown}"
  case "$ds_remote" in
    *ddoghq/dd-source*)
      ok_cfg "dd-source remote" "$DD_SOURCE_REPO"
      ;;
    *DataDog/dd-source*)
      warn "dd-source remote" "points at $DD_SOURCE_FROZEN_REPO, which was frozen when the repo moved on $DD_SOURCE_MIGRATED_ON"
      info "If this clone has in-flight branches or PRs, carry them over with the migration FAQ's procedure: git dd ddoghq-migrate"
      info "Otherwise clone $DD_SOURCE_REPO fresh."
      ;;
    "")
      warn "dd-source remote" "no origin remote found"
      ;;
    *)
      warn "dd-source remote" "unrecognised origin: $ds_remote"
      ;;
  esac
fi

# --- Bazel toolchain ---
checking "bzl wrapper (never call raw bazel)"
if have bzl; then
  ok "bzl wrapper" "$(command -v bzl)"
  info "Invoke Bazel only through bzl, and only from inside the repo workspace."
else
  warn "bzl wrapper" "not on PATH — laptop-setup.sh installs it"
fi

if have bazel && ! have bzl; then
  warn "Raw bazel" "bazel is on PATH but bzl is not — the instructions are explicit that builds go through bzl"
elif have bazel; then
  info "raw bazel is also on PATH at $(command -v bazel) — use bzl regardless"
fi

checking "rapid CLI (Rapid framework internal services)"
if have rapid; then
  ok "rapid CLI" "$(command -v rapid)"
  info "If your first PR touches an internal service built on Rapid, use the rapid CLI exclusively."
else
  manual "rapid CLI" "not installed — needed only if your PR touches a Rapid-framework internal service"
fi

checking "devcontainer config (optional but recommended)"
if [ -n "$dd_source_any" ] && [ -d "$dd_source_any/.devcontainer/workspaces/primary" ]; then
  ok_cfg "devcontainer" "$dd_source_any/.devcontainer/workspaces/primary"
  info "Recommended over bare-metal. Optional."
elif [ -n "$dd_source_any" ]; then
  warn "devcontainer" "no .devcontainer/workspaces/primary in $dd_source_any"
else
  skipped "devcontainer" "no dd-source checkout"
fi

info "After changing Go, Python or proto imports, regenerate BUILD files with Gazelle."
info "Stale import paths you may still see come from the Datadog-wide Go module path change (~110k files, tracked as $GO_MODULE_PATH_TICKET). Not a trainee task."

# --- dd-doctor ---
hdr "Step 6 — Validate with dd-doctor"

if [ -z "$dd_source_any" ]; then
  skipped "dd-doctor" "no dd-source checkout to run it in"
elif ! have bzl; then
  skipped "dd-doctor" "bzl is not installed — run: bzl run $DD_DOCTOR_TARGET from the repo root once it is"
elif [ "$SKIP_DOCTOR" -eq 1 ]; then
  skipped "dd-doctor" "--skip-doctor — run manually: cd $dd_source_any && bzl run $DD_DOCTOR_TARGET"
else
  checking "bzl run $DD_DOCTOR_TARGET in $dd_source_any (timeout ${DOCTOR_TIMEOUT}s)"
  info "A cold Bazel cache makes the first run slow. Use --skip-doctor to leave it out, or --doctor-timeout to raise the budget."
  doc_out="$(cd "$dd_source_any" && run_timeout "$DOCTOR_TIMEOUT" bzl run "$DD_DOCTOR_TARGET" </dev/null 2>&1)"
  doc_rc=$?
  printf '%s\n' "$doc_out" >> "$LOG_FILE"
  doc_out="$(printf '%s' "$doc_out" | sed -E $'s/\033\\[[0-9;]*m//g')"
  if [ $doc_rc -eq 0 ]; then
    ok_cfg "dd-doctor" "passed"
  elif [ $doc_rc -eq 137 ]; then
    warn "dd-doctor" "exceeded ${DOCTOR_TIMEOUT}s and was stopped — run it yourself: cd $dd_source_any && bzl run $DD_DOCTOR_TARGET"
  else
    warn "dd-doctor" "exit $doc_rc — see the tail below and the full output in the log"
    printf '%s' "$doc_out" | tail -25 | while IFS= read -r line; do info "$line"; done
    info "Bazel-specific failures: see the 'Debugging Bazel' guide. Anything broader: the 'Debugging & how-to' guides."
  fi
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

hdr "Summary"

for row in ${RESULTS[@]+"${RESULTS[@]}"}; do
  status="${row%%|*}"; rest="${row#*|}"
  item="${rest%%|*}"; detail="${rest#*|}"
  detail="$(printf '%s' "$detail" | tr '\n' ' ' | sed -e 's/\\n/ /g' -e 's/  */ /g')"
  if [ "${#detail}" -gt 110 ]; then
    detail="${detail:0:107}..."
  fi
  case "$status" in
    OK)        color="$C_GREEN" ;;
    INSTALLED) color="$C_CYAN" ;;
    FAILED)    color="$C_RED" ;;
    MANUAL)    color="$C_MAGENTA" ;;
    *)         color="$C_YELLOW" ;;
  esac
  emit "$(printf '  %s%-11s%s %-34s %s' "$color" "[$status]" "$C_RESET" "$item" "${C_DIM}${detail}${C_RESET}")"
done

emit ""
emit "  ${C_GREEN}OK: ${N_OK}${C_RESET}  ${C_CYAN}installed: ${N_INSTALLED}${C_RESET}  ${C_YELLOW}warn: ${N_WARN}${C_RESET}  ${C_YELLOW}skipped: ${N_SKIPPED}${C_RESET}  ${C_MAGENTA}manual: ${N_MANUAL}${C_RESET}  ${C_RED}failed: ${N_FAILED}${C_RESET}"
emit ""
emit "  ${C_DIM}Full log: ${LOG_FILE}${C_RESET}"

if [ $((N_FAILED + N_MANUAL + N_WARN)) -gt 0 ]; then
  exit 1
fi
exit 0
