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
    open my $fh, '<:encoding(UTF-8)', $path or die "$path: $!";
    local $/;
    return <$fh>;
}

my $runner = slurp('t/test_commands.pl');
my $t379   = slurp('t/cases/379_usercommands_export_dedup.t');
my $t384   = slurp('t/cases/384_schema_drift_refdata.t');

like($runner, qr/MB301: assertion methods must behave like Test::More predicates/,
    'runner contains MB301 assertion-return marker');
like($runner, qr/return \$ok \? 1 : 0;/,
    'Assert::_result returns an explicit boolean');
like($runner, qr/^sub diag \{/m,
    'Assert exposes a Test::More-style diag method');
like($runner, qr/MB301: a broken case must fail that case, not abort the whole runner/,
    'runner contains MB301 execution guard marker');
like($runner, qr/my \$executed = eval \{\s*\$code->\(\$assert,/s,
    'test case closure executes inside eval');
like($runner, qr/\$assert->fail\("\$name: execution"\)/,
    'caught case exceptions become assertion failures');
like($runner, qr/ERREUR d'execution/,
    'caught case exceptions produce a visible diagnostic');

like($t379, qr/\$assert->diag/,
    'export dedup test uses the supported diag API');
like($t384, qr/scalar\(grep \{/,
    'schema drift test forces grep into scalar context');
like($t384, qr/ref\(\$_\) eq 'HASH'/,
    'schema drift grep guards entry type before dereference');
unlike($t384, qr/\$assert->\(\s*grep \{/s,
    'schema drift test no longer passes a greedy grep list to the assertion callback');

done_testing();
