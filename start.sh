#!/bin/bash
killall -q conky
sleep 0.5
conky -q -d -c "$HOME/.config/conky/Mimod/Mimod.conf"
exit 0
