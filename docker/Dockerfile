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
ENV DEBIAN_FRONTEND=noninteractive \
    TERM=xterm-256color \
    CHOOSENIM_NO_ANALYTICS=1
RUN apt-get update \
 && apt-get install -y --no-install-recommends tmux git ca-certificates \
 && rm -rf /var/lib/apt/lists/*
# Agent CLIs. Pin nothing — get current releases at build time.
RUN npm install -g @anthropic-ai/claude-code @openai/codex \
 && npm cache clean --force
COPY --from=orchbuild /src/orch /usr/local/bin/orch
WORKDIR /work
CMD ["sleep", "infinity"]
