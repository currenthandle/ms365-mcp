#!/bin/sh
# Install a staging build of ms365-mcp.
#
# Default behavior — install the latest release candidate:
#   curl -fsSL https://raw.githubusercontent.com/currenthandle/ms365-mcp/staging/install-staging.sh | sh
#
# Pin to a specific tag (useful for reproducing a tester's environment):
#   curl -fsSL https://raw.githubusercontent.com/currenthandle/ms365-mcp/staging/install-staging.sh | sh -s -- --tag v0.1.0-rc.3
#
# Staging builds are published as GitHub pre-releases tagged
# vX.Y.Z-rc.N. They are NOT stable — for stable installs use install.sh.
set -e

REPO="currenthandle/ms365-mcp"
INSTALL_DIR="${HOME}/.local/bin"

# --- Argument parsing -------------------------------------------------

TAG=""
while [ $# -gt 0 ]; do
    case "$1" in
        --tag)
            TAG="$2"
            shift 2
            ;;
        --tag=*)
            TAG="${1#--tag=}"
            shift
            ;;
        -h|--help)
            echo "Usage: install-staging.sh [--tag vX.Y.Z-rc.N]"
            echo ""
            echo "Without --tag, installs the latest release candidate."
            echo "With --tag, installs that specific tag."
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            echo "Usage: install-staging.sh [--tag vX.Y.Z-rc.N]" >&2
            exit 1
            ;;
    esac
done

# --- Resolve the tag to install --------------------------------------

if [ -z "${TAG}" ]; then
    # No --tag supplied: ask GitHub's API for all releases (which
    # includes pre-releases — /releases/latest excludes them) and grab
    # the most recent one. The API returns newest first by default.
    TAG=$(curl -fsSL "https://api.github.com/repos/${REPO}/releases?per_page=10" \
        | grep '"tag_name"' \
        | head -1 \
        | cut -d'"' -f4)
    if [ -z "${TAG}" ]; then
        echo "Error: could not determine latest release candidate." >&2
        exit 1
    fi
fi

# --- Detect platform --------------------------------------------------

OS="$(uname -s)"
ARCH="$(uname -m)"

case "${OS}" in
    Darwin)
        case "${ARCH}" in
            arm64)  BINARY="ms365-mcp-macos-arm64" ;;
            x86_64) BINARY="ms365-mcp-macos-x86_64" ;;
            *)      echo "Unsupported architecture: ${ARCH}" >&2; exit 1 ;;
        esac
        ;;
    Linux)
        case "${ARCH}" in
            aarch64) BINARY="ms365-mcp-linux-arm64" ;;
            x86_64)  BINARY="ms365-mcp-linux-x86_64" ;;
            *)       echo "Unsupported architecture: ${ARCH}" >&2; exit 1 ;;
        esac
        ;;
    *)
        echo "Unsupported OS: ${OS}" >&2; exit 1
        ;;
esac

echo "Installing ms365-mcp ${TAG} (${OS} ${ARCH})..."

URL="https://github.com/${REPO}/releases/download/${TAG}/${BINARY}"
mkdir -p "${INSTALL_DIR}"

# Remove any prior install before downloading. Forces a fresh inode so
# any MCP client / shell / signature cache pointing at the old file
# resolves cleanly to the new one on next spawn.
rm -f "${INSTALL_DIR}/ms365-mcp"

curl -fsSL "${URL}" -o "${INSTALL_DIR}/ms365-mcp"
chmod +x "${INSTALL_DIR}/ms365-mcp"

# Defensive: clear macOS quarantine xattr if anything set one along the
# way. curl doesn't set it, but this is cheap insurance against the
# occasional "binary won't run" mystery that costs testers 10 minutes.
xattr -d com.apple.quarantine "${INSTALL_DIR}/ms365-mcp" 2>/dev/null || true

echo "Installed staging build ${TAG} to ${INSTALL_DIR}/ms365-mcp"

case ":${PATH}:" in
    *":${INSTALL_DIR}:"*) ;;
    *) echo "Add ${INSTALL_DIR} to your PATH: export PATH=\"\${HOME}/.local/bin:\${PATH}\"" ;;
esac

echo "Note: this is a pre-release build — may include in-progress features."
echo "Run 'ms365-mcp --version' to confirm the install."
