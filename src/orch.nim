## orch — tmux multi-agent orchestrator CLI
##
## Brings up a fixed tmux layout — conductor(orchestrator) + worker1/2/3 + human —
## where the conductor (Claude) and the human inject prompts into each pane's REPL
## via `orch tell <role> "..."`. Follows the CLI style of ../abus.
##
##   orch init                create the workspace (.orch/) with config + conductor prompt
##   orch up | start          bring up the 5-pane layout
##   orch attach              attach to the running tmux session
##   orch tell <role> <msg>   send to a role (resolved via the pane's @orch_role)
##   orch say <msg>           send to the orchestrator (sugar for `tell orchestrator`)
##   orch broadcast <msg>     send to worker1 -> worker2 -> worker3
##   orch status | ps         show session/pane state
##   orch down | kill         tear down the session

import std/[os, strutils, tables, sets]
import ./config
import ./tmux

# Recognized leading options. --dir (workspace) is universal; value-less flags are
# per-command (only `init` accepts --force). Everything else — an unknown --foo or
# the message body — is content, so `tell worker2 hi --x` keeps --x and
# `say --dir D --force` sends "--force" (--force is not a flag for `say`).
const
  ValueOpts = ["dir"].toHashSet           # take a value: "--dir DIR" or "--dir=DIR"
  InitFlags* = ["force"].toHashSet        # `init --force`; no flags for other commands

type Parsed* = tuple[rest: seq[string], opts: Table[string, string], flags: HashSet[string]]

proc parseArgs*(argv: seq[string], flagOpts: HashSet[string]): Parsed =
  ## Parse only *leading* options. Option parsing stops at the first token that is
  ## not a recognized option (or an explicit `--`); from there on everything is
  ## returned verbatim in `rest`. This keeps message bodies intact — a role name,
  ## a plain word, an unknown `--foo`, or a flag this command doesn't accept all end
  ## option parsing, so message text is never swallowed. `flagOpts` is the set of
  ## value-less flags valid for *this* command. Options must precede the message; to
  ## start a message with `--dir`/`--force` literally, separate it with `--`.
  result.opts = initTable[string, string]()
  result.flags = initHashSet[string]()
  var i = 0
  while i < argv.len:
    let a = argv[i]
    if a == "--":
      inc i; break                        # explicit end of options; rest is verbatim
    elif a.startsWith("--"):
      let name = a[2 .. ^1]
      if '=' in name:
        let parts = name.split('=', 1)
        if parts[0] notin ValueOpts: break  # not a value option -> message content
        result.opts[parts[0]] = parts[1]
      elif name in ValueOpts:
        inc i
        if i >= argv.len:
          raise newException(ValueError, "option --" & name & " requires a value")
        result.opts[name] = argv[i]
      elif name in flagOpts:
        result.flags.incl name
      else:
        break                             # unknown/not-for-this-command --opt -> content
    else:
      break                               # first positional -> rest is verbatim
    inc i
  while i < argv.len:
    result.rest.add argv[i]; inc i

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
      Send to a role (orchestrator|worker1|worker2|worker3|human).
      Everything after <role> is the message, verbatim — newlines and --flags in
      the text are kept (options like --dir must come before <role>).
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
  let id = paneIdByRole(s.session, role)
  if id.len == 0:
    raise newException(ValueError,
      "no pane for role '" & role & "' in session '" & s.session & "'")
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
    # Only `init` accepts a value-less flag (--force); for every other command a
    # leading --force is message content, not an option.
    let flagOpts = if sub == "init": InitFlags else: initHashSet[string]()
    let p = parseArgs(argv[1 .. ^1], flagOpts)
    if p.opts.hasKey("dir"):              # --dir overrides ORCH_DIR for all commands
      putEnv("ORCH_DIR", p.opts["dir"])

    template needArgs(n: int, usage: string) =
      if p.rest.len < n:
        stderr.writeLine("usage: " & usage); quit(1)

    # Non-message commands take no body, so any leftover token is a mistake —
    # typically a typo'd option (e.g. `--froce`) that ended option parsing and
    # fell into rest. Reject it instead of silently ignoring it (and the real
    # options after it, like an unread --dir).
    template noArgs() =
      if p.rest.len > 0:
        stderr.writeLine("error: unexpected argument '" & p.rest[0] &
          "' for `orch " & sub & "` (did you misspell an option?)")
        quit(1)

    case sub
    of "init": noArgs(); cmdInit("force" in p.flags)
    of "up", "start": noArgs(); cmdUp()
    of "attach": noArgs(); cmdAttach()
    of "tell":
      needArgs(2, "orch tell <role> <message...>")
      cmdTell(p.rest[0], p.rest[1 .. ^1].join(" "))
    of "say":
      needArgs(1, "orch say <message...>")
      cmdTell("orchestrator", p.rest[0 .. ^1].join(" "))
    of "broadcast", "all":
      needArgs(1, "orch broadcast <message...>")
      cmdBroadcast(p.rest[0 .. ^1].join(" "))
    of "status", "ps": noArgs(); cmdStatus()
    of "down", "kill": noArgs(); cmdDown()
    of "help", "--help", "-h": echo HelpText
    else:
      stderr.writeLine("unknown command: " & sub & "\n")
      stderr.writeLine(HelpText); quit(1)
  except CatchableError as e:
    stderr.writeLine("error: " & e.msg)
    quit(1)

when isMainModule:
  main()
