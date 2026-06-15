## Unit tests for orch. These exercise pure functions (config parsing, command
## building) and run without a tmux server. Run: nimble test

import std/[unittest, os, strutils, sets, tables]
import ../src/config
import ../src/tmux
import ../src/orch

# Mirror main()'s per-command flag selection: only `init` accepts --force.
proc parse(sub: string, args: varargs[string]): Parsed =
  let flags = if sub == "init": InitFlags else: initHashSet[string]()
  parseArgs(@args, flags)

suite "config":
  test "parseSettings keeps shell command verbatim (quotes/spaces/$())":
    let s = parseSettings(defaultConfig())
    check s.session == "orch"
    check s.launchFor("worker1") == "claude --model opus"
    # A TOML literal string preserves quotes and $() with no escaping.
    check s.launchFor("orchestrator") ==
      "claude --append-system-prompt \"$(cat .orch/conductor.md)\""
    check s.launchFor("human") == ""        # empty launch = plain shell

  test "loadSettings reads default config from a dir":
    let dir = getTempDir() / "orch_test_cfg"
    removeDir(dir)
    createDir(dir)
    writeFile(dir / ConfigName, defaultConfig())
    let s = loadSettings(dir)
    check s.session == "orch"
    check s.launchFor("worker2").contains("codex")
    check s.launchFor("orchestrator").contains("conductor.md")
    removeDir(dir)

  test "launchFor rejects unknown role":
    var s: Settings
    expect ValueError:
      discard s.launchFor("nope")

suite "tmux command builders":
  test "buildUpCommands: layout order, pane-id capture, pane commands":
    let s = Settings(session: "orch", launch: ["O", "W1", "W2", "W3", ""])
    let steps = buildUpCommands(s, shell = "/bin/bash")

    # 1. new-session creates the top-left (orchestrator) and captures @po
    check steps[0].args[0] == "new-session"
    check steps[0].capture == "@po"
    check steps[0].args[^1] == "O; exec /bin/bash"

    # 2. right column (worker1) via horizontal split, captures @pr
    check steps[1].args[0] == "split-window"
    check "-h" in steps[1].args
    check "@po" in steps[1].args               # split the left pane
    check steps[1].capture == "@pr"

    # 3. bottom-left (human) via vertical split. Empty launch -> a plain shell
    check steps[2].capture == "@ph"
    check "-v" in steps[2].args
    check steps[2].args[^1] == "/bin/bash"

    # 4/5. split the right column into worker2 -> worker3
    check steps[3].capture == "@pw2"
    check steps[3].args[^1] == "W2; exec /bin/bash"
    check "@pr" in steps[3].args               # split the worker1 pane
    check steps[4].capture == "@pw3"
    check steps[4].args[^1] == "W3; exec /bin/bash"
    check "@pw2" in steps[4].args              # split the worker2 pane

    # All five roles get stamped onto @orch_role (a pane user option, not the
    # clobberable #{pane_title}), in order, and identity steps are fatal.
    var roled: seq[string]
    for st in steps:
      if st.args.len >= 2 and st.args[0] == "set-option" and "@orch_role" in st.args:
        check st.fatal                       # role assignment must abort up on failure
        roled.add st.args[^1]
    check roled == @["orchestrator", "worker1", "human", "worker2", "worker3"]

    # The cosmetic border steps reference @orch_role and stay non-fatal.
    var borderFmt = ""
    for st in steps:
      if st.args.len >= 2 and st.args[0] == "set-window-option" and
         st.args[^2] == "pane-border-format":
        borderFmt = st.args[^1]
        check not st.fatal
    check borderFmt.contains("@orch_role")

  test "sendKeysCmds splits literal text and Enter":
    let cmds = sendKeysCmds("%3", "hello --x")
    check cmds.len == 2
    check cmds[0] == @["send-keys", "-t", "%3", "-l", "--", "hello --x"]
    check cmds[1] == @["send-keys", "-t", "%3", "Enter"]

suite "arg parsing (message body stays verbatim)":
  test "tell: everything after the role is verbatim, including --flags":
    # The originally-reported bugs: --foo must not be swallowed.
    check parse("tell", "human", "--foo").rest == @["human", "--foo"]
    check parse("tell", "worker2", "hello", "--x").rest == @["worker2", "hello", "--x"]

  test "tell: leading --dir is an option, then role + verbatim body":
    let p = parse("tell", "--dir", "/tmp/ws", "worker2", "hi", "--x")
    check p.opts["dir"] == "/tmp/ws"
    check p.rest == @["worker2", "hi", "--x"]

  test "say/broadcast: a body starting with --force is NOT consumed (init-only flag)":
    # Regression: `say --dir D --force` must send "--force", not usage-error.
    let p = parse("say", "--dir", "/tmp/orch-review2", "--force")
    check p.opts["dir"] == "/tmp/orch-review2"
    check p.rest == @["--force"]
    check "force" notin p.flags
    check parse("broadcast", "--force", "rebuild").rest == @["--force", "rebuild"]

  test "init: --force IS a flag, --dir takes a value":
    let p = parse("init", "--dir", "/tmp/ws", "--force")
    check p.opts["dir"] == "/tmp/ws"
    check "force" in p.flags
    check p.rest.len == 0

  test "explicit -- forces the rest to be verbatim body":
    check parse("say", "--", "--dir", "x").rest == @["--dir", "x"]

  test "a single-token message starting with -- is kept verbatim":
    check parse("say", "--dir is a flag").rest == @["--dir is a flag"]

  test "typo'd option surfaces in rest (and stops --dir being read) so main can reject it":
    # `init --froce --dir X`: --froce is unknown -> parsing stops there, so the
    # typo lands first in rest AND --dir is never parsed. main's noArgs() rejects
    # the leftover instead of silently creating .orch/ in the cwd.
    let p = parse("init", "--froce", "--dir", "/tmp/orch-review-typo")
    check p.rest == @["--froce", "--dir", "/tmp/orch-review-typo"]
    check not p.opts.hasKey("dir")        # the real --dir was NOT consumed
    check "force" notin p.flags
