# datadog-backend-setup

An idempotent audit-and-install script for the Datadog backend track on macOS: the
dual-identity signing gate, `laptop-setup.sh`, GitLab CI/CD access, and the `dd-source`
repo (Bazel, `dd-doctor`, `rapid`, Gazelle).

**Backend track only.** Frontend-only contributors should skip this entirely — that track
is self-contained and does not need `laptop-setup.sh`.

## What it reports

Every item prints exactly one status:

| Status        | Meaning                                                          |
| ------------- | ---------------------------------------------------------------- |
| `[OK]`        | already installed / already configured — nothing to do             |
| `[INSTALLED]` | was missing, this script installed it                              |
| `[FAILED]`    | was attempted and failed                                           |
| `[MANUAL]`    | cannot be automated (GUI app, Chrome extension, interactive login) |
| `[SKIPPED]`   | skipped by you, or by `--check-only` / `--dry-run`                 |
| `[WARN]`      | present, but not in the state the instructions expect              |

Exit status is `0` only when nothing is failing, warning, or pending.

## Usage

```bash
./dd-backend-setup-check.sh                   # audit, then prompt before each change
./dd-backend-setup-check.sh --check-only      # audit only, change nothing
./dd-backend-setup-check.sh --dry-run         # print the commands, run nothing
./dd-backend-setup-check.sh --yes             # apply fixes without prompting
./dd-backend-setup-check.sh --no-network      # skip every check that hits the network
./dd-backend-setup-check.sh --run-laptop-setup
./dd-backend-setup-check.sh --skip-doctor     # skip the Bazel dd-doctor run
./dd-backend-setup-check.sh --doctor-timeout 1800
./dd-backend-setup-check.sh --help
```

Safe to re-run. Full output also goes to `~/dd-backend-setup-check-<ts>.log`.

## What it checks

**The signing gate comes first.** Nothing downstream runs until `git config-tool doctor`
is fully green, because `laptop-setup.sh` is hours of work to spend against a broken
identity setup. The check parses the `N/M checks passed` score rather than the exit code,
and does **not** compare against a fixed total — that number moves with configuration and
working directory (23/24, 31/31 and 34/34 all occurred on one machine in one day, while
the published runbook quoted 27/27). What it gates on instead is: every check passing,
*and* commit-signing checks actually running. A green `23/23` with `manage-signing = false`
in `tool.toml` means doctor verified nothing whatsoever about signing.

It also checks the active `gh` account before offering `git config-tool setup`, since
setup manages signing keys through whichever account `gh` has active. With a personal and
a work account both logged in, the active one is easily the wrong one — and the tool's own
advice (`gh auth refresh --scopes admin:ssh_signing_key`) would grant that scope to the
personal account and sign under it. The script prefers switching accounts to widening
scopes, and says why.

**laptop-setup.sh** — checks a copy is present *and is actually a shell script*. `devtools`
is private, so the documented `curl -Lo .../raw/...` quietly saves a login page when
unauthenticated: a large, non-empty file that is not a script at all. It prefers the copy
in your `devtools` clone (authoritative, no download needed), validates the shebang,
rejects HTML, and offers to delete any invalid copy — an HTML file named `.sh` is a live
hazard. Running it sits behind an explicit `--run-laptop-setup` and is deliberately **not**
implied by `--yes`: it takes hours, asks for sudo repeatedly, and can pull tens of GB.

The documented gotcha is checked *before* the run rather than after: the script edits
`~/.zshrc`, and on some new laptops that file's permissions block writes, so the env vars
silently never appear. Afterwards it re-reads `DATADOG_ROOT` through a fresh login shell,
which is how that gotcha actually surfaces.

**GitLab for CI/CD** — `ddtool` against its `>= v1.87.0` floor, then the short-lived token
flow: it reads a token non-interactively (the command exits 0 with empty output when logged
out, so it never opens a browser or blocks), and runs the documented `/api/v4/user` sanity
check. It also looks for traces of the deprecated Personal Access Token + Keychain flow and
says so, rather than quietly leaving you on it.

**dd-source** — canonical path is `~/go/src/github.com/ddoghq/dd-source`. Note this is the
*opposite* of `web-ui`, whose local path keeps saying `DataDog`; both are correct as
documented and the script does not normalise one to the other. It verifies the remote
points at `ddoghq/dd-source`, since `DataDog/dd-source` was frozen when the repo moved on
2026-06-25, and points at the migration FAQ's `git dd ddoghq-migrate` procedure when there
are in-flight branches to carry over. It then checks the `bzl` wrapper (builds go through
`bzl`, never raw `bazel`), the `rapid` CLI, and the optional devcontainer config, and notes
the Gazelle step for regenerating BUILD files after Go/Python/proto import changes.

**Validation** — `bzl run //:dd-doctor` from the repo root, with a 900s default because a
cold Bazel cache makes the first run slow.

## Notes

Where a step needs you present — `git config-tool setup`, `ddtool auth gitlab login` — the
script offers to run it and hands you the terminal, rather than piping its output somewhere
you can't answer a prompt. Where a step genuinely cannot be automated (the Chrome Web
Store, joining a Slack channel) it reports `[MANUAL]` with the link.

One failure mode worth calling out because it reads as something else: older `vault` builds
set `GODEBUG=x509sha1=1` for themselves, the token helper inherits it, and Go toolchains
that removed the setting abort at startup. `vault token lookup` then looks like a missing
token when it is really a stale `vault` binary.

## Requirements

macOS and `bash`. Everything else it will offer to install.
