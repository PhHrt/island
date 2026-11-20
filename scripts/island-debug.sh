#!/bin/zsh
# Envoie une commande de debug à Island : toggle (ouvre/ferme l'île) ou toast (simule un branchement).
osascript -l JavaScript -e "ObjC.import('Foundation'); \$.NSDistributedNotificationCenter.defaultCenter.postNotificationNameObjectUserInfoDeliverImmediately('dev.island.debug', '${1:-toggle}', \$(), true)"
