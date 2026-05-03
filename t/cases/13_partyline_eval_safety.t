# t/cases/13_partyline_eval_safety.t
# =============================================================================
# Regression test for Partyline .eval safety.
#
# Protects against the dangerous in-process eval implementation returning:
#   eval { local $_ = undef; eval $code; }
#
# Expected current behavior:
#   - .eval is Owner-only
#   - confirmation expires after 30 seconds
#   - code runs in a forked subprocess
#   - subprocess has a hard timeout
#   - old STDOUT/STDERR scalar-ref capture is gone
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub {
    my ($src, $name) = @_;

    my $needle = "sub $name";
    my $start = index($src, $needle);
    die "sub $name not found" if $start < 0;

    my $brace = index($src, "{", $start);
    die "opening brace for $name not found" if $brace < 0;

    my $depth = 0;
    my $in_single = 0;
    my $in_double = 0;
    my $in_comment = 0;
    my $escape = 0;

    for (my $i = $brace; $i < length($src); $i++) {
        my $c = substr($src, $i, 1);

        if ($in_comment) {
            $in_comment = 0 if $c eq "\n";
            next;
        }

        if ($in_single) {
            if ($c eq "\\" && !$escape) {
                $escape = 1;
                next;
            }
            if ($c eq "'" && !$escape) {
                $in_single = 0;
            }
            $escape = 0;
            next;
        }

        if ($in_double) {
            if ($c eq "\\" && !$escape) {
                $escape = 1;
                next;
            }
            if ($c eq '"' && !$escape) {
                $in_double = 0;
            }
            $escape = 0;
            next;
        }

        if ($c eq "#") {
            $in_comment = 1;
            next;
        }

        if ($c eq "'") {
            $in_single = 1;
            next;
        }

        if ($c eq '"') {
            $in_double = 1;
            next;
        }

        if ($c eq "{") {
            $depth++;
        }
        elsif ($c eq "}") {
            $depth--;
            if ($depth == 0) {
                return substr($src, $start, $i - $start + 1);
            }
        }
    }

    die "end of sub $name not found";
}

return sub {
    my ($assert) = @_;

    my $partyline = _slurp(File::Spec->catfile('.', 'Mediabot', 'Partyline.pm'));
    my $sample_a  = _slurp(File::Spec->catfile('.', 'mediabot.sample.conf'));
    my $sample_b  = _slurp(File::Spec->catfile('.', 'Mediabot', 'mediabot.sample.conf'));

    my $eval_sub = _extract_sub($partyline, '_cmd_eval');

    $assert->ok(
        $eval_sub =~ /Access denied: \.eval requires Owner level/,
        'Partyline .eval remains Owner-only'
    );

    $assert->ok(
        $eval_sub =~ /\(\$now_eval - \(\$self->\{\$pending_key\}\{at\} \/\/ 0\)\) > 30/,
        'Partyline .eval confirmation expires after 30 seconds'
    );

    $assert->ok(
        $eval_sub =~ /PARTYLINE_EVAL_TIMEOUT_SECONDS/,
        'Partyline .eval reads PARTYLINE_EVAL_TIMEOUT_SECONDS'
    );

    $assert->ok(
        $eval_sub =~ /open\(my \$pipe,\s*"-\|"\)/,
        'Partyline .eval runs through a forked subprocess pipe'
    );

    $assert->ok(
        $eval_sub =~ /Eval timed out after \$\{eval_timeout\}s/,
        'Partyline .eval reports timeout'
    );

    $assert->ok(
        $eval_sub !~ /eval \{\s*local \$_ = undef;\s*eval \$code;\s*\}/s,
        'Partyline .eval old in-process eval block is absent'
    );

    $assert->ok(
        $eval_sub !~ /open\(STDOUT,\s*['"]>>['"],\s*\\\$output\)/,
        'Partyline .eval old STDOUT scalar-ref capture is absent'
    );

    $assert->ok(
        $eval_sub !~ /open\(STDERR,\s*['"]>>['"],\s*\\\$output\)/,
        'Partyline .eval old STDERR scalar-ref capture is absent'
    );

    $assert->ok(
        $sample_a =~ /PARTYLINE_EVAL_TIMEOUT_SECONDS=5/,
        'root sample config documents PARTYLINE_EVAL_TIMEOUT_SECONDS'
    );

    $assert->ok(
        $sample_b =~ /PARTYLINE_EVAL_TIMEOUT_SECONDS=5/,
        'Mediabot sample config documents PARTYLINE_EVAL_TIMEOUT_SECONDS'
    );
};
