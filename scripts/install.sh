#!/usr/bin/env bash
# Installs mathascii into irssi's scripts directory, replacing any older copy.
#
# Usage: scripts/install.sh [--home DIR] [--autorun]
#
#   --home DIR   irssi's home directory (default: ~/.irssi)
#   --autorun    also link it into scripts/autorun so irssi loads it at startup
#
# Run it again after pulling changes to update the installed copy.
set -euo pipefail

usage() {
    sed -n 's/^# \{0,1\}//; 4,9p' "$0"
}

home="$HOME/.irssi"
autorun=0
while (($#)); do
    case $1 in
        --home)
            [[ $# -ge 2 && -n $2 ]] || { echo "install.sh: --home needs a directory" >&2; usage >&2; exit 2; }
            home=$2
            shift 2
            ;;
        --autorun)
            autorun=1
            shift
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            echo "install.sh: unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

source=$(cd "$(dirname "$0")/.." && pwd)/src/mathascii.pl
scripts=$home/scripts
mkdir -p "$scripts"
cp "$source" "$scripts/mathascii.pl"
echo "installed $scripts/mathascii.pl"

if ((autorun)); then
    mkdir -p "$scripts/autorun"
    ln -sfn ../mathascii.pl "$scripts/autorun/mathascii.pl"
    echo "linked $scripts/autorun/mathascii.pl, so irssi will load it at startup"
fi

echo "in irssi: /script load mathascii   (run it again to pick up a newer copy)"
