#!/bin/sh
# One-line install: curl -fsSL https://raw.githubusercontent.com/currenthandle/ms365-mcp/main/install.sh | sh
set -e

REPO="currenthandle/ms365-mcp"
INSTALL_DIR="${HOME}/.local/bin"

# Detect OS and architecture.
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

# Get the latest release tag.
LATEST=$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" | grep '"tag_name"' | head -1 | cut -d'"' -f4)
if [ -z "${LATEST}" ]; then
    echo "Error: could not determine latest release."
    exit 1
fi

echo "Installing ms365-mcp ${LATEST} (${OS} ${ARCH})..."

# Download the binary.
URL="https://github.com/${REPO}/releases/download/${LATEST}/${BINARY}"
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

echo "Installed to ${INSTALL_DIR}/ms365-mcp"

# Check if INSTALL_DIR is in PATH.
case ":${PATH}:" in
    *":${INSTALL_DIR}:"*) ;;
    *) echo "Add ${INSTALL_DIR} to your PATH: export PATH=\"\${HOME}/.local/bin:\${PATH}\"" ;;
esac

echo "Done! Run 'ms365-mcp' to start the server."
