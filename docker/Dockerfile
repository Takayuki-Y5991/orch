# orch-box — an isolated environment to run the orchestrator squad in FULL-AUTO
# (no permission prompts) without exposing the host. The container boundary
# (namespaces + cgroups) is the isolation; Docker's default seccomp-BPF profile
# is applied automatically. Build context = the repo root:
#   docker build -t orch-box:latest -f docker/Dockerfile .
#
# Contains: tmux, the orch CLI (built from source), and the two agent CLIs
# (Claude Code + Codex). Credentials are NOT baked in — the launcher copies them
# into a running container at `orch-box up` time.

# ---- stage 1: build the orch binary from source (statically linked) ----
FROM nimlang/nim:latest AS orchbuild
WORKDIR /src
COPY orch.nimble .
COPY src ./src
# Static link so the binary is independent of the runtime image's glibc.
RUN nimble build -d:release --passL:-static -y \
 && strip orch \
 && ./orch help >/dev/null

# ---- stage 2: runtime with tmux + the agent CLIs ----
FROM node:24-bookworm-slim
# IS_SANDBOX=1: this image is an externally-sandboxed environment, so Claude Code
# permits --dangerously-skip-permissions to run as root inside it.
# LANG/LC_ALL=C.UTF-8: without a UTF-8 locale bash/readline can't accept multibyte
# input (e.g. Japanese) in the human pane. C.UTF-8 is built into glibc — no
# `locales` package needed.
ENV DEBIAN_FRONTEND=noninteractive \
    TERM=xterm-256color \
    IS_SANDBOX=1 \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8
RUN apt-get update \
 && apt-get install -y --no-install-recommends tmux git ca-certificates \
 && rm -rf /var/lib/apt/lists/*
# Agent CLIs. Pin nothing — get current releases at build time.
RUN npm install -g @anthropic-ai/claude-code @openai/codex \
 && npm cache clean --force \
 # Claude Code looks for its own CLI at ~/.local/bin/claude; point it at the npm
 # install so it doesn't warn "claude command ... missing or broken".
 && mkdir -p /root/.local/bin \
 && ln -sf /usr/local/bin/claude /root/.local/bin/claude
COPY --from=orchbuild /src/orch /usr/local/bin/orch
WORKDIR /work
CMD ["sleep", "infinity"]
