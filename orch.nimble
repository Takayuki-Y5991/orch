# orch — tmux multi-agent orchestrator CLI
version       = "0.1.0"
author        = "konkon"
description   = "tmux multi-agent orchestrator: conductor(Claude) + 3 workers."
license       = "MIT"
srcDir        = "src"
bin           = @["orch"]

requires "nim >= 2.0.0"
requires "parsetoml"
