# orch — tmux multi-agent orchestrator

A small Nim CLI that brings up a fixed tmux layout — **conductor (orchestrator) +
worker1/2/3 + human** — where the conductor (Claude) and the human inject prompts
into each pane's agent (claude/codex) to think through problems as a multi-agent
squad. Sibling to `../abus` (a squad-compatible message bus) and built in the same
style.

## Layout (per plan.md)

```
+----------------+----------------+
| orchestrator   |   worker1      |
+----------------+----------------+
|                |   worker2      |
|     human      +----------------+
|                |   worker3      |
+----------------+----------------+
```

- **top-left orchestrator** … `claude` with a conductor system prompt (the conductor)
- **bottom-left human** … a plain shell; use `orch say "..."` to talk to the conductor
- **right worker1/2/3** … Claude Opus / Codex (high) / Claude Sonnet by default

## Design

- **The conductor is Claude Code.** It takes the human's request, decomposes it,
  delegates to the workers in turn with `orch tell workerN "..."`, then integrates
  the results and reports back. Its prompt lives in `.orch/conductor.md`.
- **Dispatch is tmux `send-keys` injection.** The body (literal) and Enter are sent
  as two separate keystrokes, so messages with newlines or `--foo` are safe.
- **Addressing is by pane title.** tmux renumbers pane indices on split, so each
  pane gets a title via `select-pane -T <role>` and `orch tell` resolves
  title -> pane id with `list-panes`.
- **orch does not interpret launch commands.** It just runs the configured command
  string in each pane, so swapping claude -> gemini is a config edit, nothing more.

## Build

```bash
nimble build                                  # -> ./orch
# or: nim c -d:release --mm:orc -o:orch src/orch.nim
nimble test                                   # unit tests
```

Dependencies: the standard library, the system `tmux`, and one pure-Nim package
(`parsetoml`) for the TOML config.

## Usage

```bash
orch init                          # create .orch/config.toml and conductor.md
$EDITOR .orch/config.toml          # tweak each worker's launch if needed
orch up                            # bring up the 5-pane layout
orch attach                        # attach (other terminal: tmux attach -t orch)

orch tell worker3 "what is 1+1?"   # ask worker3 (Sonnet) directly
orch say "compare 3 auth designs"  # ask the conductor (it fans out to workers)
orch broadcast "weaknesses here?"  # send to worker1 -> worker2 -> worker3

orch status                        # session / pane state
orch down                          # tear down the session
```

> Run `orch up` from the **directory that contains `.orch/`** (the default conductor
> launch reads `$(cat .orch/conductor.md)` by relative path). To run elsewhere, set
> `ORCH_DIR` to an absolute path and adjust the orchestrator launch if needed.

## Config (`.orch/config.toml`)

TOML. Each role has a `launch` shell command run in its pane. An empty `launch`
gives a plain interactive shell. `launch` is stored as a TOML **literal string**
(single quotes) so quotes / spaces / `$(...)` are preserved verbatim.

```toml
[session]
name = "orch"

[orchestrator]
launch = 'claude --append-system-prompt "$(cat .orch/conductor.md)"'

[worker1]
launch = "claude --model opus"

[worker2]
launch = "codex --model gpt-5.5 -c model_reasoning_effort=high"

[worker3]
launch = "claude --model sonnet"

[human]
launch = ""
```

Edit the codex model/effort flags and anything else freely — orch does not parse them.

## Commands

| Command | What it does |
|---|---|
| `orch init [--dir DIR] [--force]` | Create the workspace with config and conductor prompt |
| `orch up` (alias `start`) | Bring up the 5-pane layout |
| `orch attach` | Attach to the running session |
| `orch tell <role> <msg...>` | Send to a role (pane title) |
| `orch say <msg...>` | Send to the orchestrator |
| `orch broadcast <msg...>` (alias `all`) | Send to worker1 -> worker2 -> worker3 |
| `orch status` (alias `ps`) | Show state |
| `orch down` (alias `kill`) | Tear down the session |

Env: `ORCH_DIR` (default `.orch`; overridden by `--dir`).

## Source files

| File | Role |
|---|---|
| `src/config.nim` | TOML config read/write; default config / conductor generation |
| `src/tmux.nim` | tmux wrapper; pure command builders separated from execution |
| `src/orch.nim` | CLI parsing (abus style) and subcommand dispatch |
| `tests/test_orch.nim` | Pins config parsing, layout building, and send-keys assembly |

## Limitations / future

- The v1 layout is a **fixed 5 panes** (orchestrator/worker1-3/human). A dynamic
  layout for a variable number of workers is future work.
- Results are observed by watching the panes. For structured history collection,
  pair this with `../abus`.
