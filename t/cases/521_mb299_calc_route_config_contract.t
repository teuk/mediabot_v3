#!/usr/bin/env perl
use strict;
use warnings;
use FindBin qw($Bin);
use File::Spec;
use Test::More;

my $root = File::Spec->rel2abs("$Bin/../..");
sub slurp {
    my ($rel) = @_;
    my $path = File::Spec->catfile($root, split m{/}, $rel);
    open my $fh, '<', $path or die "$path: $!";
    local $/;
    return <$fh>;
}

my $calc   = slurp('plugins/scripts/examples/calc.py');
my $readme = slurp('plugins/scripts/README.md');
my $sample = slurp('mediabot.sample.conf');
my $commit_path = File::Spec->catfile($root, 'commit.sh');
my $commit = -f $commit_path ? slurp('commit.sh') : undef;
my $t520   = slurp('t/cases/520_mb298_calc_reference_plugin.t');

like($readme, qr/ships seven examples/, 'README counts seven external examples');
like($readme, qr/`pcalc`\s*\|\s*Python\s*\|\s*safe AST-based arithmetic calculator/,
    'README lists pcalc reference route');
like($readme, qr/COMMANDS=hello,pyhello,tclhello,proll,p8ball,pchoose,pcalc/,
    'README command scope includes pcalc');
like($readme, qr/pcalc=examples\/calc\.py/,
    'README route map includes calc.py');
like($readme, qr/internal `roll`,\s*`8ball`, `choose` and `calc` commands/s,
    'README explains the internal calc collision');

# mb528-B1: la liste d'exemples continue apres pcalc (premind) ; le contrat
# mb299 reste "pcalc est dans le scope d'exemple", pas "pcalc est le dernier".
like($sample, qr/^#COMMANDS=hello,pyhello,tclhello,proll,p8ball,pchoose,pcalc(?:,|$)/m,
    'sample command scope includes pcalc');
like($sample, qr/pcalc=examples\/calc\.py/,
    'sample route map includes calc.py');
like($sample, qr/`roll`, `8ball`, `choose` and `calc`/,
    'sample explains the internal calc collision');
unlike($sample, qr/^COMMANDS=.*\bpcalc\b/m,
    'sample does not activate pcalc');
unlike($sample, qr/^ROUTES=.*\bpcalc=/m,
    'sample does not activate the calculator route');

like($calc, qr/return _check_size\(node\.value\)/,
    'calc validates numeric literals before formatting');
like($calc, qr/except ZeroDivisionError:\s*\n\s*raise CalcError\("division by zero"\)/,
    'calc catches zero raised to a negative power');
unlike($calc, qr/^#\s+!calc\b/m,
    'calc documentation does not advertise the internal command');
like($calc, qr/^#\s+pcalc 2 \+ 2 \* 3/m,
    'calc documentation advertises the routed alias');

like($t520, qr/positive infinity literal is rejected cleanly/,
    'calc regression covers non-finite literals');
like($t520, qr/zero to a negative power is reported without crashing/,
    'calc regression covers negative powers of zero');
SKIP: {
    skip 'commit.sh is a local-only maintainer tool', 2 unless defined $commit;
    like($commit, qr/t\/cases\/520_mb298_calc_reference_plugin\.t/,
        'commit preflight includes the calculator runtime test');
    like($commit, qr/t\/cases\/521_mb299_calc_route_config_contract\.t/,
        'commit preflight includes the calculator route/config contract');
}

done_testing();
