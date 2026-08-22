#!/usr/bin/perl
use strict;
use warnings;
use File::Basename qw(dirname);
use File::Spec;

return sub {
    my ($assert) = @_;

    my $runner = File::Spec->catfile(dirname(__FILE__), '..', 'test_commands.pl');
    open my $fh, '<:encoding(UTF-8)', $runner
        or return $assert->fail("open compact test runner source");
    local $/;
    my $src = <$fh> // '';
    close $fh;

    $assert->like(
        $src,
        qr/sub\s+_compact_failure_output\s*\{/,
        "runner has a compact failure formatter",
    );

    $assert->like(
        $src,
        qr/my\s+\$max\s*=\s*260\s*;/,
        "compact failure lines are length-capped",
    );

    $assert->like(
        $src,
        qr/my\s+\$max_lines\s*=\s*8\s*;/,
        "compact failure output is line-capped",
    );

    $assert->like(
        $src,
        qr/print\s+"\$text\\n"\s+if\s+length\(\$text\)\s+&&\s+\$self->\{verbose\}/,
        "Assert diagnostics are full only in verbose mode",
    );

    $assert->like(
        $src,
        qr/print\s+\$output\s*;\s*\}\s*else\s*\{\s*my\s+\$compact\s*=\s*_compact_failure_output/s,
        "isolated TAP is compact outside verbose mode",
    );

    $assert->like(
        $src,
        qr/output\s*=>\s*_compact_failure_output\(\$args\{name\},\s*\$output\)/s,
        "progress mode stores compact failure details only",
    );

    $assert->like(
        $src,
        qr/print\s+"\\n\[\s+\$name\s+\]\\n"\s+if\s+\$opt_verbose\s*;/,
        "per-case headers are hidden outside verbose mode",
    );

    $assert->unlike(
        $src,
        qr/print\s+"\$row->\{output\}\\n\\n"\s*;/,
        "progress mode no longer dumps raw captured case output",
    );

    $assert->like(
        $src,
        qr/Failed test files \(%d\)/,
        "progress mode prints a compact failed-file summary",
    );
};
