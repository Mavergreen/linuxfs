cmake_minimum_required(VERSION 3.16)
# usage: configured by build/build-updater.sh only, with LINUXFS_VERSION and the pinned clang22, to build
#        linuxfs-updater.app
set(LINUXFS_VERSION "" CACHE STRING "the full version, <UPSTREAM_VERSION>-mavericks.N")
if(LINUXFS_VERSION STREQUAL "")
  message(FATAL_ERROR "configure through build/build-updater.sh: LINUXFS_VERSION is required")
endif()
project(linuxfs-updater LANGUAGES OBJC)

find_package(MavericksShipyard REQUIRED)
set(MAVERICKS_REQUIRE_APPLECLANG OFF)
include(Mavericks)
include(MavericksSparkle)
# spec: updater/ICON-CREDIT.txt -- the generic macOS application icon, by explicit opt-in
mavericks_add_updater_app(
  PRODUCT linuxfs
  PRODUCT_NAME "Mavericks Linux Filesystems"
  ALLOW_GENERIC
  VERSION "${LINUXFS_VERSION}"
  ED_PUBKEY_FILE "${CMAKE_CURRENT_SOURCE_DIR}/ed25519_key.pub"
  LOG_PREFIX "MavLinuxFSUpdater"
  CONFIRM_TITLE "Mavericks Linux Filesystems updated"
  CONFIRM_BODY "Linux Filesystems for Mavericks was updated. Volumes mounted from now on use the new version."
)
