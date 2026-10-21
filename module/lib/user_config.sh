#!/system/bin/sh
# Where the user config lives (spec #59). Sourced by every stage that generates
# rules, so the path is written down once.
#
# Outside the module directory on purpose: a module update or reinstall replaces
# that directory, and with it anything the user chose inside it. Overridable so
# the suite can run a stage on a host; the default is the only value a device uses.

NOEMULATOR_USER_CONFIG=${NOEMULATOR_USER_CONFIG:-/data/adb/noemulator-user.conf}
