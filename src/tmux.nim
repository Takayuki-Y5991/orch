## tmux — a thin wrapper around the tmux CLI.
##
## Testability: command *construction* lives in pure functions
## (buildUpCommands / sendKeysCmds), separate from execution (tmuxExec) and
## pane-id substitution. This lets the builders be unit-tested without a tmux
## server.

import std/[os, strutils, tables]
import ./config

var tmpCounter {.global.}: int = 0

type UpStep* = object
  args*: seq[string]    # @po/@pr/@ph/@pw2/@pw3 are pane-id placeholders (resolved at run time)
  capture*: string      # "" = capture nothing; otherwise store stdout (new pane id) under this key
  fatal*: bool          # if true, a non-zero exit aborts runUp (identity steps); cosmetic steps are non-fatal

proc paneCmd(launch, shell: string): seq[string] =
  ## argv to run in a pane. Empty launch -> a plain shell. Otherwise
  ## `sh -c '<launch>; exec <shell>'` (so $(...) expands and the pane survives
  ## after the agent exits).
  let l = launch.strip
  if l.len == 0: @[shell]
  else: @["sh", "-c", l & "; exec " & shell]

proc buildUpCommands*(s: Settings, shell = getEnv("SHELL", "/bin/bash")): seq[UpStep] =
  ## Build the plan.md layout step by step, capturing each new pane id.
  ##   top-left=orchestrator / bottom-left=human / right top->bottom=worker1,2,3
  let sess = s.session
  result = @[
    UpStep(args: @["new-session", "-d", "-s", sess, "-P", "-F", "#{pane_id}"] &
                 paneCmd(s.launchFor("orchestrator"), shell), capture: "@po"),
    # -d: don't make the new pane active (avoids touching the terminal/stdin, so
    #     it won't block when run from a non-tty context). Panes are addressed by
    #     their @orch_role user option, not by active state.
    UpStep(args: @["split-window", "-d", "-h", "-t", "@po", "-P", "-F", "#{pane_id}"] &
                 paneCmd(s.launchFor("worker1"), shell), capture: "@pr"),
    UpStep(args: @["split-window", "-d", "-v", "-t", "@po", "-P", "-F", "#{pane_id}"] &
                 paneCmd(s.launchFor("human"), shell), capture: "@ph"),
    UpStep(args: @["split-window", "-d", "-v", "-t", "@pr", "-P", "-F", "#{pane_id}"] &
                 paneCmd(s.launchFor("worker2"), shell), capture: "@pw2"),
    UpStep(args: @["split-window", "-d", "-v", "-t", "@pw2", "-P", "-F", "#{pane_id}"] &
                 paneCmd(s.launchFor("worker3"), shell), capture: "@pw3"),
    # Stamp each pane's role into the @orch_role *pane user option*. Unlike
    # #{pane_title} (which the program inside the pane overwrites via OSC title
    # escapes — claude shows "✳ Claude Code", a shell shows the cwd), user options
    # are owned by tmux and never touched by the pane's program, so role lookup
    # stays stable. Identity steps are fatal: a missing role makes `tell` unusable.
    UpStep(args: @["set-option", "-p", "-t", "@po", "@orch_role", "orchestrator"], fatal: true),
    UpStep(args: @["set-option", "-p", "-t", "@pr", "@orch_role", "worker1"], fatal: true),
    UpStep(args: @["set-option", "-p", "-t", "@ph", "@orch_role", "human"], fatal: true),
    UpStep(args: @["set-option", "-p", "-t", "@pw2", "@orch_role", "worker2"], fatal: true),
    UpStep(args: @["set-option", "-p", "-t", "@pw3", "@orch_role", "worker3"], fatal: true),
    # Show the role on the pane borders (cosmetic; non-fatal if it fails).
    UpStep(args: @["set-window-option", "-t", sess, "pane-border-status", "top"], capture: ""),
    UpStep(args: @["set-window-option", "-t", sess, "pane-border-format", " #{@orch_role} "], capture: ""),
  ]

proc sendKeysCmds*(paneId, text: string): seq[seq[string]] =
  ## Split into two sends: literal body, then Enter. Keeps text containing
  ## newlines or --foo safe.
  @[
    @["send-keys", "-t", paneId, "-l", "--", text],
    @["send-keys", "-t", paneId, "Enter"],
  ]

# ── Execution side (effects). Runs the tmux binary. ─────────────────────────

proc tmuxExec*(args: openArray[string]): tuple[output: string, code: int] =
  ## Run tmux and return its stdout(+stderr) and exit code.
  ##
  ## Note: when tmux daemonizes its server it can keep the parent's stdout
  ## **pipe** open, so capturing via a pipe makes readAll hang (no EOF). We
  ## redirect output to a temp file instead (a regular file always yields EOF
  ## even with other writers). Args are joined with quoteShell, so quotes /
  ## spaces / $() in launch survive, and $(...) is evaluated by the inner
  ## `sh -c` at pane start (not by this outer shell).
  inc tmpCounter
  let tmp = getTempDir() / ("orch-tmux-" & $getCurrentProcessId() & "-" & $tmpCounter)
  var parts = @["tmux"]
  for a in args: parts.add quoteShell(a)
  let cmd = parts.join(" ") & " > " & quoteShell(tmp) & " 2>&1"
  let code = execShellCmd(cmd)
  var output = ""
  if fileExists(tmp):
    output = readFile(tmp)
    removeFile(tmp)
  (output, code)

proc tmuxAvailable*(): bool = findExe("tmux").len > 0

proc sessionExists*(session: string): bool =
  tmuxExec(["has-session", "-t", session]).code == 0

proc runUp*(s: Settings) =
  ## Run buildUpCommands in order, resolving @xx placeholders to the captured pane ids.
  var ids = initTable[string, string]()
  for step in buildUpCommands(s):
    var args = newSeq[string](step.args.len)
    for i, a in step.args:
      args[i] = ids.getOrDefault(a, a)   # a placeholder -> real id, otherwise unchanged
    let res = tmuxExec(args)
    # A step aborts up if it must succeed: capture steps (we need the pane id) and
    # fatal identity steps (@orch_role). Cosmetic steps (border) are ignored.
    if res.code != 0 and (step.capture.len > 0 or step.fatal):
      raise newException(IOError, "tmux " & args.join(" ") & " failed:\n" & res.output)
    if step.capture.len > 0:
      ids[step.capture] = res.output.strip

proc paneIdByRole*(session, role: string): string =
  ## Return the pane id whose @orch_role user option matches, or "" if not found.
  ## Reads the role from a tmux user option (not #{pane_title}), so it survives the
  ## pane's program rewriting its terminal title.
  let res = tmuxExec(["list-panes", "-s", "-t", session, "-F", "#{pane_id} #{@orch_role}"])
  if res.code != 0: return ""
  for line in res.output.splitLines():
    let ln = line.strip
    if ln.len == 0: continue
    let sp = ln.find(' ')
    if sp < 0: continue
    if ln[sp+1 .. ^1].strip == role: return ln[0 ..< sp]
  return ""

proc sendKeys*(paneId, text: string) =
  for c in sendKeysCmds(paneId, text):
    let res = tmuxExec(c)
    if res.code != 0:
      raise newException(IOError, "tmux send-keys failed:\n" & res.output)

proc killSession*(session: string) =
  let res = tmuxExec(["kill-session", "-t", session])
  if res.code != 0:
    raise newException(IOError, "kill-session failed:\n" & res.output)

proc listPanes*(session: string): string =
  ## Show the role from @orch_role (stable), plus the live #{pane_title} the inner
  ## program is showing, so it's clear which agent occupies each role's pane.
  tmuxExec(["list-panes", "-s", "-t", session,
            "-F", "#{pane_id}  #{@orch_role}  [#{pane_current_command}]  #{pane_title}"]).output
