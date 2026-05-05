# t/cases/108_sample_conf_no_duplicate_keys.t
# =============================================================================
# Regression checks for mediabot.sample.conf duplicate keys.
#
# The sample config is meant to be copied and edited by humans. Duplicate
# uncommented keys in the same section are confusing because the later value may
# silently override the earlier one depending on parser behavior.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_sample_no_duplicate_keys {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    my $sample = _slurp_sample_no_duplicate_keys(
        File::Spec->catfile('.', 'mediabot.sample.conf')
    );

    my $section = '';
    my %seen;
    my @dups;

    my @lines = split /\n/, $sample;

    for my $idx (0 .. $#lines) {
        my $line = $lines[$idx];
        my $lineno = $idx + 1;

        $line =~ s/^\s+|\s+$//g;

        next if $line eq '';
        next if $line =~ /^#/;

        if ($line =~ /^\[([^\]]+)\]$/) {
            $section = $1;
            next;
        }

        next unless $section ne '';
        next unless $line =~ /^([A-Za-z0-9_]+)=/;

        my $key  = $1;
        my $full = "$section.$key";

        if (exists $seen{$full}) {
            push @dups, "$full at lines $seen{$full} and $lineno";
        } else {
            $seen{$full} = $lineno;
        }
    }

    $assert->is(
        join(', ', @dups),
        '',
        'mediabot.sample.conf has no duplicate uncommented keys inside the same section'
    );

    my $eval_timeout_count = () = $sample =~ /^PARTYLINE_EVAL_TIMEOUT_SECONDS=5$/mg;

    $assert->is(
        $eval_timeout_count,
        1,
        'PARTYLINE_EVAL_TIMEOUT_SECONDS appears exactly once as an active sample key'
    );

    $assert->like(
        $sample,
        qr/^PARTYLINE_EVAL_ENABLED=0$/m,
        'PARTYLINE_EVAL_ENABLED remains documented'
    );
};
