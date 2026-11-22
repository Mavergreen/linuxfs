# platform: host-agnostic
# spec: mavergreen-conventions SKILL.md "Install layout and identity" -- sourced by build scripts; the one place
#       the install prefix and short name are spelled
if [ -z "${REPO_ROOT:-}" ]; then
  [ -f ./build/lib.sh ] || { echo "lib.sh: set REPO_ROOT, or source from the repo root" >&2; return 1 2>/dev/null || exit 1; }
  REPO_ROOT="$(pwd)"
fi
LINUXFS_SHORT=linuxfs
LINUXFS_PREFIX="${LINUXFS_PREFIX:-/usr/local/mavergreen/linuxfs}"
export REPO_ROOT LINUXFS_SHORT LINUXFS_PREFIX
upstream_version() { tr -d ' \t\r\n' < "$REPO_ROOT/UPSTREAM_VERSION"; }
