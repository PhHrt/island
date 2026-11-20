#!/usr/bin/perl
# Charge mr_adapter.dylib dans le processus perl (signé Apple) et appelle island_run.
use strict;
use warnings;
use DynaLoader;

my $lib_path = shift or die "usage: run.pl <chemin/mr_adapter.dylib>\n";
my $lib = DynaLoader::dl_load_file($lib_path, 0) or die "[perl] chargement impossible: " . DynaLoader::dl_error() . "\n";
my $sym = DynaLoader::dl_find_symbol($lib, "island_run") or die "[perl] island_run introuvable\n";
DynaLoader::dl_install_xsub("main::island_run", $sym);
island_run();
