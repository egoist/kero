#!/bin/sh
# Kero's lid helper keeps a Mac awake with its lid closed, on battery
# too, while Kero keeps it awake: pmset's disablesleep, which only root
# can set. Kero installs it as /Library/PrivilegedHelperTools/
# sh.kero.lid-awake, owned by root, with a rule in /etc/sudoers.d that
# lets the user who installed it run it by sudo without a password.
#
#   sh.kero.lid-awake PID      keep the Mac awake until process PID exits,
#                              or this is sent TERM, INT or HUP
#   sh.kero.lid-awake release  let the Mac sleep, if this left it awake,
#                              as a Kero that crashed or a Mac that lost
#                              power can
#   sh.kero.lid-awake remove   release, then delete the rule of the user
#                              who ran sudo, and this script once no
#                              other user's rule is left
#
# It lets the Mac sleep again as it stops, and while the battery is at
# 10% or below. It undoes only what it did: if another app had turned
# sleep off already, it leaves it off.

PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH

# mark is there while this keeps the Mac awake, across a restart.
mark=/var/db/sh.kero.lid-awake
# helper is this script as installed, and rules each user's rule, by
# their uid.
helper=/Library/PrivilegedHelperTools/sh.kero.lid-awake
rules=/etc/sudoers.d/kero-lid-awake-

disabled() {
	pmset -g | grep -q '^[[:space:]]*SleepDisabled[[:space:]]*1'
}

low() {
	batt=$(pmset -g batt)
	case $batt in *"'Battery Power'"*) ;; *) return 1 ;; esac
	pct=$(printf '%s\n' "$batt" | sed -n 's/.*[[:space:]]\([0-9][0-9]*\)%.*/\1/p' | head -n 1)
	[ -n "$pct" ] && [ "$pct" -le 10 ]
}

release() {
	if [ -e "$mark" ]; then
		pmset -a disablesleep 0
		rm -f "$mark"
	fi
}

case $1 in
release)
	release
	exit 0
	;;
remove)
	# sudo sets SUDO_UID, which the user can't.
	case $SUDO_UID in '' | *[!0-9]*)
		echo "$0: remove runs by sudo" >&2
		exit 2
		;;
	esac
	release
	rm -f "$rules$SUDO_UID"
	for r in "$rules"*; do
		[ -e "$r" ] && exit 0
	done
	rm -f "$helper"
	exit 0
	;;
'' | *[!0-9]*)
	echo "usage: $0 PID | release | remove" >&2
	exit 2
	;;
esac
pid=$1

trap 'release; exit 0' TERM INT HUP
while kill -0 "$pid" 2>/dev/null; do
	if low; then
		release
	elif ! disabled; then
		pmset -a disablesleep 1 && touch "$mark"
	fi
	sleep 5 &
	wait $!
done
release
