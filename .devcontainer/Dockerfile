# based on https://github.com/anthropics/claude-code/tree/main/.devcontainer
# and https://www.chainguard.dev/unchained/migrating-a-node-js-application-to-chainguard-images

# Build island (https://github.com/landlock-lsm/island) — Landlock-based filesystem sandbox.
# Uses +crt-static to produce a fully static binary that works in any Linux environment.
FROM cgr.dev/chainguard/rust:latest-dev AS island-builder
USER root
ENV CARGO_HOME=/cargo
RUN cargo install --git https://github.com/landlock-lsm/island island

FROM cgr.dev/chainguard/node:latest-dev

ARG CLAUDE_CODE_VERSION=latest

# Switch to root for package installation
USER root

# Copy island binary from builder stage
COPY --from=island-builder /cargo/bin/island /usr/local/bin/island

# Install basic development tools and iptables/ipset
RUN apk update && apk add \
  less \
  git \
  procps \
  fzf \
  man-db \
  unzip \
  gnupg \
  iptables \
  ipset \
  iproute2 \
  bind-tools \
  jq \
  vim \
  wget \
  bash \
  su-exec \
  && rm -rf /var/cache/apk/*

ARG USERNAME=dev

# Create non-root user
RUN addgroup ${USERNAME} && adduser -D -G ${USERNAME} -s /bin/bash ${USERNAME}

# Ensure default dev user has access to /usr/local/share
RUN mkdir -p /usr/local/share/npm-global && \
  chown -R ${USERNAME}:${USERNAME} /usr/local/share

# Persist bash history.
RUN SNIPPET="export PROMPT_COMMAND='history -a' && export HISTFILE=/commandhistory/.bash_history" \
  && mkdir /commandhistory \
  && touch /commandhistory/.bash_history \
  && chown -R ${USERNAME} /commandhistory

# Set `DEVCONTAINER` environment variable to help with orientation
ENV DEVCONTAINER=true

# Create workspace and config directories and set permissions
RUN mkdir -p /workspace /home/${USERNAME}/.claude /home/${USERNAME}/.config/npm && \
  touch /home/${USERNAME}/.npmrc && \
  chown -R ${USERNAME}:${USERNAME} /workspace /home/${USERNAME}/.claude \
    /home/${USERNAME}/.config /home/${USERNAME}/.npmrc

WORKDIR /workspace

# Set up non-root user
USER dev

# Install global packages
ENV NPM_CONFIG_PREFIX=/usr/local/share/npm-global
ENV PATH=$PATH:/usr/local/share/npm-global/bin

# Set the default editor and visual
ENV EDITOR=vim
ENV VISUAL=vim

# Install npm itself into the npm-global prefix so the shim can find it at
# /usr/local/share/npm-global/bin/npm, then install Claude Code.
# Both installs happen before the npm shim is in place, so they run unsandboxed.
RUN npm install -g npm && \
    npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}

# Switch back to root to deploy island profiles, shims, and shell aliases
USER root

# Island profiles (Landlock sandbox policies per-tool)
COPY --chown=${USERNAME}:${USERNAME} island/profiles/ /home/${USERNAME}/.config/island/profiles/

# Binary shims: wrap npm and git with island sandboxing
COPY scripts/shims/ /usr/local/bin/
RUN chmod +x /usr/local/bin/npm /usr/local/bin/git

# Shell alias: 'claude' runs via island claude-code profile
COPY --chown=${USERNAME}:${USERNAME} bash_aliases /home/${USERNAME}/.bash_aliases
RUN printf '[ -f ~/.bash_aliases ] && . ~/.bash_aliases\n' > /home/${USERNAME}/.bashrc && \
    chown ${USERNAME}:${USERNAME} /home/${USERNAME}/.bashrc

# Switch back to root for firewall setup
USER root

# Set up network firewall scripts and log infrastructure
COPY scripts/ /opt/scripts/
COPY extra-whitelist.conf /opt/scripts/extra-whitelist.conf
RUN chmod +x /opt/scripts/*.sh && \
    touch /var/log/firewall.log /var/log/firewall-status.txt && \
    chmod 644 /var/log/firewall.log /var/log/firewall-status.txt

ENTRYPOINT ["/opt/scripts/entrypoint.sh"]
CMD ["sleep", "infinity"]
