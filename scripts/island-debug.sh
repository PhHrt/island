#!/bin/zsh
# Commande de debug pour Island : toggle (ouvre/ferme l'île), toast (simule un branchement), headphones (annonce la sortie audio courante).
osascript -l JavaScript -e "ObjC.import('Foundation'); \$.NSDistributedNotificationCenter.defaultCenter.postNotificationNameObjectUserInfoDeliverImmediately('dev.island.debug', '${1:-toggle}', \$(), true)"
