#!/usr/bin/env perl
use strict;
use warnings;
use FindBin qw($Bin);
use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

my $root = File::Spec->rel2abs("$Bin/../..");
my $path = File::Spec->catfile($root, 'install', 'db_install.sh');

open my $fh, '<:encoding(UTF-8)', $path or die "$path: $!";
local $/;
my $src = <$fh>;
close $fh;

like(
    $src,
    qr/escaped=\$\{escaped\/\/\\\\\/\\\\\\\\\}/,
    'SQL literal helper doubles backslashes with Bash parameter expansion',
);
like(
    $src,
    qr/escaped=\$\{escaped\/\/\\'\/\\'\\'\}/,
    'SQL literal helper doubles single quotes with Bash parameter expansion',
);
unlike(
    $src,
    qr/escaped=\$\(printf.*?\|\s*sed/s,
    'broken sed-based SQL quoting is gone',
);

for my $name (qw(MYSQL_DB_USER AUTH_HOST MYSQL_DB_PASS)) {
    like(
        $src,
        qr/^\Q${name}_SQL=\E\$\(sql_string_literal "\$$name"\)\s*\|\|\s*exit 1$/m,
        "$name SQL literal conversion is checked explicitly",
    );
}

like(
    $src,
    qr/DROP USER IF EXISTS \$\{MYSQL_DB_USER_SQL\}\@\$\{AUTH_HOST_SQL\}/,
    'verification rollback uses quoted account literals and is idempotent',
);
unlike(
    $src,
    qr/DROP USER '\$\{MYSQL_DB_USER\}'\@'\$\{AUTH_HOST\}'/,
    'verification rollback does not embed raw user/host values',
);

my ($func) = $src =~ /(sql_string_literal\(\)\s*\{.*?^\})/ms;
ok(defined($func) && length($func), 'sql_string_literal function extracted');

my $tmp = tempdir(CLEANUP => 1);
my $runner = File::Spec->catfile($tmp, 'quote.sh');
open my $rfh, '>:encoding(UTF-8)', $runner or die "$runner: $!";
print {$rfh} <<'HEADER';
#!/bin/bash
messageln() { :; }
HEADER
print {$rfh} $func, "\n";
print {$rfh} <<'FOOTER';
sql_string_literal "$1"
FOOTER
close $rfh;
chmod 0755, $runner or die "chmod $runner: $!";

sub run_quote {
    my ($value) = @_;
    my $pid = open my $out, '-|';
    die "fork: $!" unless defined $pid;
    if ($pid == 0) {
        open STDERR, '>', File::Spec->devnull() or die $!;
        exec 'bash', $runner, $value;
        die "exec: $!";
    }
    local $/;
    my $text = <$out> // '';
    close $out;
    return ($? >> 8, $text);
}

my @cases = (
    [ 'simple',       'simple',        q{'simple'} ],
    [ 'backslash',    'a\\b',          "'a\\\\b'" ],
    [ 'single quote', "a'b",          q{'a''b'} ],
    [ 'both',         "a'\\b",        "'a''\\\\b'" ],
    [ 'spaces',       'a b c',         q{'a b c'} ],
);

for my $case (@cases) {
    my ($label, $value, $expected) = @$case;
    my ($rc, $out) = run_quote($value);
    is($rc, 0, "$label value is accepted");
    is($out, $expected, "$label value is quoted exactly");
}

my ($newline_rc, $newline_out) = run_quote("line1\nline2");
isnt($newline_rc, 0, 'newline-bearing value is rejected');
is($newline_out, '', 'rejected newline value emits no SQL literal');

done_testing();
