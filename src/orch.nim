## orch — tmux multi-agent orchestrator CLI
##
## Brings up a fixed tmux layout — conductor(orchestrator) + worker1/2/3 + human —
## where the conductor (Claude) and the human inject prompts into each pane's REPL
## via `orch tell <role> "..."`. Follows the CLI style of ../abus.
##
##   orch init                create the workspace (.orch/) with config + conductor prompt
##   orch up | start          bring up the 5-pane layout
##   orch attach              attach to the running tmux session
##   orch tell <role> <msg>   send to a role (= pane title)
##   orch say <msg>           send to the orchestrator (sugar for `tell orchestrator`)
##   orch broadcast <msg>     send to worker1 -> worker2 -> worker3
##   orch status | ps         show session/pane state
##   orch down | kill         tear down the session

import std/[os, strutils, tables, sets]
import ./config
import ./tmux

# Long options that take a value ("--key value" with a space is allowed).
const ValueOpts = ["dir"].toHashSet

type Parsed = tuple[pos: seq[string], opts: Table[string, string], flags: HashSet[string]]

proc parseArgs(argv: seq[string]): Parsed =
  result.opts = initTable[string, string]()
  result.flags = initHashSet[string]()
  var i = 0
  var noMoreOpts = false                  # everything after '--' is a positional (message body)
  while i < argv.len:
    let a = argv[i]
    if not noMoreOpts and a == "--":
      noMoreOpts = true
    elif not noMoreOpts and a.startsWith("--"):
      let name = a[2 .. ^1]
      if '=' in name:
        let parts = name.split('=', 1)
        result.opts[parts[0]] = parts[1]
      elif name in ValueOpts:
        inc i
        if i >= argv.len:
          raise newException(ValueError, "option --" & name & " requires a value")
        result.opts[name] = argv[i]
      else:
        result.flags.incl name            # value-less flags like --force
    else:
      result.pos.add a
    inc i

const HelpText = """
orch — tmux multi-agent orchestrator (conductor + 3 workers; zero-dep native CLI)

Brings up a fixed tmux layout where a conductor (Claude) and the human inject
prompts into each pane's agent (claude/codex) to work as a multi-agent squad.
orch does not interpret launch commands — it just runs the configured command
string in each pane (so you can swap claude/codex/gemini by editing config).

Layout (per plan.md):
  +----------------+----------------+
  | orchestrator   |   worker1      |
  +----------------+----------------+
  |                |   worker2      |
  |     human      +----------------+
  |                |   worker3      |
  +----------------+----------------+

USAGE
  orch <command> [args] [options]
  orch help | --help | -h

WORKSPACE
  init [--dir DIR] [--force]
      Create the workspace (default .orch/) with config.toml and conductor.md.
      Run once. Won't overwrite existing files without --force.
  up   (alias: start)
      Read config, build the 5-pane layout, and run each role's launch command.
      Errors if a session with the same name is already running.
  attach
      Attach to the running tmux session (tmux attach -t <session>).
  down (alias: kill)
      Kill the session.
  status (alias: ps)
      Show whether the session is running and list its panes (id/title/command).

DISPATCH
  tell <role> <message...>
      Send to a role (pane title: orchestrator|worker1|worker2|worker3|human).
      The text is typed into that pane's REPL and submitted with Enter.
  say <message...>
      Send to the orchestrator (sugar for `tell orchestrator`; human -> conductor).
  broadcast <message...>   (alias: all)
      Send the same message to worker1 -> worker2 -> worker3 in order.

ENV
  ORCH_DIR      Workspace location (default: ./.orch). --dir overrides it.

EXAMPLES
  orch init                         # create .orch/config.toml and conductor.md
  $EDITOR .orch/config.toml         # tweak each worker's launch if needed
  orch up                           # bring up the layout
  orch attach                       # attach (or: tmux attach -t orch)
  orch tell worker3 "what is 1+1?"  # ask worker3 (Sonnet) directly
  orch say "compare 3 auth designs" # ask the conductor (it fans out to workers)
  orch broadcast "weaknesses here?" # send to all workers
  orch status                       # show state
  orch down                         # tear down

EXIT STATUS
  0 success / 1 error (not initialized, session not running, unknown role/command,
  etc. — "error: ..." is written to stderr)
"""

proc cmdInit(force: bool) =
  let dir = orchDir()
  let cpath = configPath(dir)
  let kpath = conductorPath(dir)
  if not force and (fileExists(cpath) or fileExists(kpath)):
    raise newException(IOError,
      "already initialized at " & dir & "/ (use --force to overwrite)")
  createDir(dir)
  writeFile(cpath, defaultConfig())
  writeFile(kpath, defaultConductor())
  echo "initialized ", dir, "/"
  echo "  ", cpath
  echo "  ", kpath
  echo "edit ", cpath, " then run: orch up"

proc cmdUp() =
  if not tmuxAvailable():
    raise newException(IOError, "tmux not found in PATH")
  let s = loadSettings()
  if sessionExists(s.session):
    raise newException(IOError,
      "session '" & s.session & "' already running (orch attach / orch down)")
  runUp(s)
  echo "session '", s.session, "' started (", Roles.len, " panes)"
  echo "attach: tmux attach -t ", s.session, "   (or: orch attach)"

proc cmdAttach() =
  let s = loadSettings()
  if not sessionExists(s.session):
    raise newException(IOError, "session '" & s.session & "' not running (run: orch up)")
  # Attaching is interactive; reuse the current terminal via the shell.
  quit(execShellCmd("tmux attach -t " & quoteShell(s.session)))

proc tellRole(s: Settings, role, msg: string) =
  let id = paneIdByTitle(s.session, role)
  if id.len == 0:
    raise newException(ValueError,
      "no pane titled '" & role & "' in session '" & s.session & "'")
  sendKeys(id, msg)

proc requireSession(): Settings =
  result = loadSettings()
  if not sessionExists(result.session):
    raise newException(IOError,
      "session '" & result.session & "' not running (run: orch up)")

proc cmdTell(role, msg: string) =
  tellRole(requireSession(), role, msg)

proc cmdBroadcast(msg: string) =
  let s = requireSession()
  for w in Workers:
    tellRole(s, w, msg)

proc cmdStatus() =
  let s = loadSettings()
  if not sessionExists(s.session):
    echo "session '", s.session, "': not running"
    return
  echo "session '", s.session, "': running"
  stdout.write listPanes(s.session)

proc cmdDown() =
  let s = loadSettings()
  if not sessionExists(s.session):
    echo "session '", s.session, "': not running"
    return
  killSession(s.session)
  echo "session '", s.session, "' killed"

proc main() =
  let argv = commandLineParams()
  if argv.len == 0:
    echo HelpText; quit(0)
  let sub = argv[0]

  # Validation/IO errors return cleanly ("error: ...") instead of a stack trace.
  try:
    let p = parseArgs(argv[1 .. ^1])
    if p.opts.hasKey("dir"):              # --dir overrides ORCH_DIR for all commands
      putEnv("ORCH_DIR", p.opts["dir"])

    template needPos(n: int, usage: string) =
      if p.pos.len < n:
        stderr.writeLine("usage: " & usage); quit(1)

    case sub
    of "init": cmdInit("force" in p.flags)
    of "up", "start": cmdUp()
    of "attach": cmdAttach()
    of "tell":
      needPos(2, "orch tell <role> <message...>")
      cmdTell(p.pos[0], p.pos[1 .. ^1].join(" "))
    of "say":
      needPos(1, "orch say <message...>")
      cmdTell("orchestrator", p.pos[0 .. ^1].join(" "))
    of "broadcast", "all":
      needPos(1, "orch broadcast <message...>")
      cmdBroadcast(p.pos[0 .. ^1].join(" "))
    of "status", "ps": cmdStatus()
    of "down", "kill": cmdDown()
    of "help", "--help", "-h": echo HelpText
    else:
      stderr.writeLine("unknown command: " & sub & "\n")
      stderr.writeLine(HelpText); quit(1)
  except CatchableError as e:
    stderr.writeLine("error: " & e.msg)
    quit(1)

main()
