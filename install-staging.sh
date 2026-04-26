#!/bin/sh
# Install the latest staging build of ms365-mcp.
#
#   curl -fsSL https://raw.githubusercontent.com/currenthandle/ms365-mcp/staging/install-staging.sh | sh
#
# Pulls from the moving `staging` GitHub release tag (updated by the
# staging.yml workflow on every push to the staging branch). NOT a stable
# release — may break.
set -e

REPO="currenthandle/ms365-mcp"
INSTALL_DIR="${HOME}/.local/bin"
TAG="staging"

OS="$(uname -s)"
ARCH="$(uname -m)"

case "${OS}" in
    Darwin)
        case "${ARCH}" in
            arm64)  BINARY="ms365-mcp-macos-arm64" ;;
            x86_64) BINARY="ms365-mcp-macos-x86_64" ;;
            *)      echo "Unsupported architecture: ${ARCH}"; exit 1 ;;
        esac
        ;;
    Linux)
        case "${ARCH}" in
            aarch64) BINARY="ms365-mcp-linux-arm64" ;;
            x86_64)  BINARY="ms365-mcp-linux-x86_64" ;;
            *)       echo "Unsupported architecture: ${ARCH}"; exit 1 ;;
        esac
        ;;
    *)
        echo "Unsupported OS: ${OS}"; exit 1
        ;;
esac

echo "Installing ms365-mcp from staging (${OS} ${ARCH})..."

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

echo "Installed staging build to ${INSTALL_DIR}/ms365-mcp"

case ":${PATH}:" in
    *":${INSTALL_DIR}:"*) ;;
    *) echo "Add ${INSTALL_DIR} to your PATH: export PATH=\"\${HOME}/.local/bin:\${PATH}\"" ;;
esac

echo "Note: this is a staging build — may include in-progress features."
echo "Run 'ms365-mcp' to start the server."
