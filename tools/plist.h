/*
 * linuxfs's preferences (the defaults domain dev.mavergreen.linuxfs) read by root-run code: the console user's plist, opened
 * as that user (never with root's reach), and the machine's in /Library/Preferences. Shared by the bundles' program (fs.c)
 * and the root helper's install-time migration (helper.c).
 */
#ifndef LINUXFS_PLIST_H
#define LINUXFS_PLIST_H

#include <CoreFoundation/CoreFoundation.h>

/* The console user's and the machine's preferences, each NULL when absent, unreadable or not a dictionary; the caller
 * releases what is not NULL. A plist counts only when it is a regular file, not a symlink, at most 1 MiB and owned by the
 * user (the machine's: by root); the user's is opened and read as the user. When not root, LINUXFS_PREFS_USER and
 * LINUXFS_PREFS_MACHINE name the two instead (tests), owned by the caller. A failure to become root again exits 254. */
void prefs_load(CFDictionaryRef *user, CFDictionaryRef *machine);

/* A preference as a boolean (also 1/0 and "YES"/"NO"/"true"/"false"), or -1 when absent or not one. D may be NULL. */
int pref_bool(CFDictionaryRef d, CFStringRef key);

#endif
