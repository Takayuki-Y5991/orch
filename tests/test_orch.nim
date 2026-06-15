## Unit tests for orch. These exercise pure functions (config parsing, command
## building) and run without a tmux server. Run: nimble test

import std/[unittest, os, strutils]
import ../src/config
import ../src/tmux

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

    # All five roles get a title, in order
    var titled: seq[string]
    for st in steps:
      if st.args.len >= 2 and st.args[0] == "select-pane" and "-T" in st.args:
        titled.add st.args[^1]
    check titled == @["orchestrator", "worker1", "human", "worker2", "worker3"]

  test "sendKeysCmds splits literal text and Enter":
    let cmds = sendKeysCmds("%3", "hello --x")
    check cmds.len == 2
    check cmds[0] == @["send-keys", "-t", "%3", "-l", "--", "hello --x"]
    check cmds[1] == @["send-keys", "-t", "%3", "Enter"]
