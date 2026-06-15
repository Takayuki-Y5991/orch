## config — read/write orch settings, stored as TOML (parsetoml).
##
## `launch` values are shell command lines, so the generated config stores them
## as TOML *literal strings* (single quotes) to preserve quotes / spaces / $()
## verbatim, with no escaping. Reading uses parsetoml's nil-safe `{}` traversal.

import std/os
import parsetoml

const
  DefaultDir* = ".orch"
  ConfigName* = "config.toml"
  ConductorName* = "conductor.md"
  # The v1 layout is a fixed 5-pane set. Role names (= pane titles), in order.
  Roles* = ["orchestrator", "worker1", "worker2", "worker3", "human"]
  Workers* = ["worker1", "worker2", "worker3"]

proc orchDir*(): string =
  ## Workspace location. Override with env ORCH_DIR (default .orch).
  getEnv("ORCH_DIR", DefaultDir)

proc configPath*(dir = orchDir()): string =
  dir / ConfigName

proc conductorPath*(dir = orchDir()): string =
  dir / ConductorName

type Settings* = object
  session*: string
  launch*: array[Roles.len, string] # parallel to Roles

proc launchFor*(s: Settings, role: string): string =
  for i, r in Roles:
    if r == role:
      return s.launch[i]
  raise newException(ValueError, "unknown role: " & role)

proc parseSettings*(text: string): Settings =
  ## Parse TOML text into Settings. Missing keys fall back to defaults.
  let toml = parsetoml.parseString(text)
  result.session = toml{"session", "name"}.getStr("orch")
  for i, role in Roles:
    result.launch[i] = toml{role, "launch"}.getStr("")

proc loadSettings*(dir = orchDir()): Settings =
  let path = configPath(dir)
  if not fileExists(path):
    raise
      newException(IOError, "config not found: " & path & " (run 'orch init' first)")
  parseSettings(readFile(path))

proc defaultConfig*(): string =
  ## Default config written by `init`. launch values use TOML literal strings
  ## (single quotes) so embedded quotes / $() are preserved verbatim.
  result = """# orch — tmux multi-agent orchestrator config
# Each role has a title (= table name) and a `launch` shell command run in its pane.
# Edit `launch` freely (swap claude/codex/gemini just by changing the string).
# launch is a TOML literal string (single quotes): quotes / spaces / $() are kept verbatim.
# An empty launch starts a plain interactive shell.

[session]
name = "orch"

# Conductor: launch claude with the conductor system prompt.
# Note: launch runs via a shell, so $(cat ...) is expanded at pane start.
#       Run `orch up` from the directory that contains .orch/.
[orchestrator]
launch = 'claude --append-system-prompt "$(cat .orch/conductor.md)"'

# worker1: Claude Opus (deep reasoning)
[worker1]
launch = "claude --model opus"

# worker2: Codex 5.5 high (implementation / verification)
[worker2]
launch = "codex --model gpt-5.5 -c model_reasoning_effort=high"

# worker3: Claude Sonnet (speed / breadth)
[worker3]
launch = "claude --model sonnet"

# human: a plain shell. From here, use `orch say "..."` to talk to the conductor.
[human]
launch = ""
"""

proc defaultConductor*(): string =
  ## Default conductor system prompt written by `init`.
  result = """# Orchestrator (Conductor)

You are the **conductor** of a multi-agent squad. You receive the human's
request, break it down, delegate tasks to the three workers in turn, then
integrate their results and report back to the human. Don't do the deep work
yourself — focus on **decomposition, sequencing, integration, and quality control**.

## Worker roster
- worker1 — Claude Opus. Deep reasoning, design, hard problems.
- worker2 — Codex (high). Implementation, code generation, verification.
- worker3 — Claude Sonnet. Fast investigation, broad exploration, drafts.

## How to delegate
Run these in a shell to inject a prompt directly into a worker's REPL:

    orch tell worker1 "<task>"
    orch tell worker2 "<task>"
    orch tell worker3 "<task>"

- By default delegate in order worker1 -> worker2 -> worker3, watching each
  pane's output before moving on.
- To ask the same question to everyone, use `orch broadcast "<question>"`.
- Read each worker's reply, point out gaps or contradictions, re-delegate if
  needed, and finally give the human an integrated summary.

## Talking with the human
The human types requests to you directly in the orchestrator pane, or runs
`orch say "..."` from the human pane. If a request is ambiguous, confirm with
the human before delegating.
"""
