# activity-report

[![CI](https://github.com/hakulab/activity-report/actions/workflows/ci.yml/badge.svg)](https://github.com/hakulab/activity-report/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

Reconstruct what you worked on over a date range, with human and agent hours per project and task, from the transcripts that [Google Antigravity CLI](https://antigravity.google/docs/cli-features) (`agy`), [Claude Code](https://claude.com/claude-code), [Codex](https://openai.com/codex/), and [OMP](https://omp.sh) keep on your machine.

## How it works

`activity-report digest` reads local transcripts and prints one JSON document for a range of local dates. Where transcripts identify a parent session, it links delegated work to the prompt that started it. It estimates human and agent hours for each day. The [agent skill](skills/activity-report/SKILL.md) uses the prompts, replies, and working directories to group those hours by project and task.

## Install

### Nix

Run it without installing:

```bash
nix run github:hakulab/activity-report -- digest 2026-10-12
```

Or install it into your profile:

```bash
nix profile install github:hakulab/activity-report
```

The package puts `git`, `sqlite3`, and `zstd` on the command's `PATH`. It covers `aarch64-darwin`, `aarch64-linux`, and `x86_64-linux`. Flakes must be enabled, as in `nix --extra-experimental-features 'nix-command flakes' run ...` on a stock install.

The first run may ask to allow the project's Cachix cache. Declining is fine, since the package builds from cache.nixos.org. Nix configurations can also use `overlays.default` to add `activity-report` to their own package set.

### Home Manager

Add the flake input and import the module:

```nix
inputs.activity-report.url = "github:hakulab/activity-report";

# In the Home Manager configuration
imports = [ inputs.activity-report.homeModules.default ];

programs.activity-report.enable = true;
```

The module installs the command and links the skill into `~/.agents/skills` and `~/.claude/skills`. Set `programs.activity-report.skillDirectories` to change those directories, or `programs.activity-report.package` to override the package built from this flake. A non-empty `programs.activity-report.settings` writes the [configuration](#configuration) below to `activity-report/config.toml`, while the default empty value omits the managed file.

### Skill directories

Home Manager creates these links for you. For a Nix-only installation, clone the repository and link the skill for the assistants that should use it:

```bash
git clone https://github.com/hakulab/activity-report ~/.local/share/activity-report
mkdir -p ~/.agents/skills "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills"
ln -s ~/.local/share/activity-report/skills/activity-report ~/.agents/skills/activity-report
ln -s ~/.local/share/activity-report/skills/activity-report "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/activity-report"
```

| Directory                                                   | Read by          |
| ----------------------------------------------------------- | ---------------- |
| `~/.agents/skills`                                          | Codex, OMP       |
| `~/.claude/skills`, or `$CLAUDE_CONFIG_DIR/skills` when set | Claude Code, OMP |

To invoke the skill from Antigravity CLI, include the home-relative path `.gemini/config/skills` in `programs.activity-report.skillDirectories` or link the skill under `~/.gemini/config/skills` manually. Link or copy the whole directory because Codex skips a `SKILL.md` that is itself a symlink. Start a new assistant session after linking.

## Configuration

The command reads `${XDG_CONFIG_HOME:-~/.config}/activity-report/config.toml`, and `--config` names another TOML file. A missing file at the default path means the built-in defaults, while a missing `--config` file is an error. Tables deep-merge over the defaults, and lists replace them. Unknown keys and type mismatches are errors that name the dotted key and resolved file.

```toml
[hours]
reading_minutes = 15
max_minutes = 90

[labels]
default = ["work"]

[labels.projects]
my-project = ["personal"]
```

| Key                        | Default                                | Meaning                                                                                          |
| -------------------------- | -------------------------------------- | ------------------------------------------------------------------------------------------------ |
| `excluded_dirs`            | `[]`                                   | Regexes matching session directories whose prompts earn no human hours, such as worker worktrees |
| `assistants.agy`           | `~/.gemini/antigravity-cli`            | Antigravity CLI session store containing `brain/`                                                |
| `assistants.claude`        | `$CLAUDE_CONFIG_DIR`, else `~/.claude` | Claude Code's state directory                                                                    |
| `assistants.codex`         | `$CODEX_HOME`, else `~/.codex`         | Codex's state directory                                                                          |
| `assistants.omp`           | `~/.omp/agent`                         | OMP's state directory                                                                            |
| `hours.reading_minutes`    | `10`                                   | Minutes a prompt earns after its agent turn ends, for reading the reply                          |
| `hours.max_minutes`        | `60`                                   | Most minutes a single prompt can earn                                                            |
| `hours.agent_max_minutes`  | `120`                                  | Most agent minutes a single turn can earn                                                        |
| `hours.agent_idle_minutes` | `30`                                   | Longest gap in minutes between a turn's records before the rest of the turn earns no time        |
| `labels.default`           | `[]`                                   | Labels given to a project without an entry in `labels.projects`. An empty list covers every task |
| `labels.projects`          | `{}`                                   | Labels of each project by repository directory name                                              |

Assistant directories must be absolute or start with `~`, which expands without resolving symlinks. Set `assistants.claude` or `assistants.codex` in TOML to override its environment-derived default.

If you keep Antigravity CLI sessions elsewhere, set `assistants.agy` to the directory containing `brain/`, or set `programs.activity-report.settings.assistants.agy` in Home Manager. Antigravity keeps shared configuration and skills under `~/.gemini/config`.

All `hours` values must be integers. `reading_minutes` allows zero, and the other values must be positive.

## Usage

### Digest

```bash
activity-report digest 2026-10-12
activity-report digest 2026-10-12 2026-10-16
activity-report digest --config ./config.toml --excerpt-chars 0 2026-10-12
```

Dates are local and use `YYYY-MM-DD` format. Leading zeros are optional for the month and day. Give the dates in chronological order to include both endpoints, or pass one date for a single day. `--excerpt-chars` keeps the first N characters of each prompt and reply, and `0` keeps the full text.

### Resolved configuration

```bash
activity-report config
activity-report config --config ./config.toml
```

`activity-report config` prints the resolved configuration as JSON, so you can inspect the merged defaults, environment fallbacks, and file overrides before running a digest.

## Output

`activity-report digest` prints one JSON document for the requested range. [Output fields](skills/activity-report/references/output.md) documents every field, its unit, and how hours are earned.

## Privacy

Treat a digest and a report as private, and redact paths, tokens, and conversation text before sharing either.

The command reads transcripts and session metadata locally. It holds no credentials, opens no network connections, and runs no commands from the assistant stores. `excluded_dirs` removes human hours from matching sessions, while their agent work remains in the digest, as a run or under the prompt that delegated to it.

The [agent skill](skills/activity-report/SKILL.md) asks the assistant to run `git`, `gh`, `glab`, `vdirsyncer`, and `khal`. Those commands read the same machine and reach the forge and calendar the user is signed in to, so install the skill only where that access is intended.

## Tested with

The transcript formats change without notice. The digest is tested on Linux against these versions:

| Assistant   | Tested  |
| ----------- | ------- |
| Claude Code | 2.1.319 |
| Codex       | 0.167.0 |
| OMP         | 18.18.1 |

Tests for Antigravity CLI use synthetic examples of the plaintext transcript format in version 1.5.18. The digest covers steps retained in those logs. Sessions available only as binary conversation files and steps removed during compaction are outside its coverage.

A newer assistant can add a record kind this command ignores, so that activity then goes uncounted. If a report misses work you know happened, open an issue with the release tag or commit you run and the assistant's version.

## Releases

Releases follow the [versioning policy](RELEASING.md#versioning), and stable releases keep the [stability surface](RELEASING.md#stability-surface) compatible within a minor version.

## Development

[`AGENTS.md`](AGENTS.md) is the contributor entry point for people and coding agents alike.

## License

Copyright (c) 2026 [Hakula](https://hakula.xyz). Licensed under the [MIT License](LICENSE).
