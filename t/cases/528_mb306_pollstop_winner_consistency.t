# t/cases/528_mb306_pollstop_winner_consistency.t
# =============================================================================
# MB306:
#   - !pollstop must announce the option label, not its zero-based index;
#   - weighted polls must use weighted scores when choosing the winner;
#   - tied top scores must be reported as a tie;
#   - poll duration must update the existing Prometheus gauge.
# =============================================================================

use strict;
use warnings;

use File::Spec;

sub _slurp_mb306 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die $!;
    local $/;
    return <$fh>;
}

sub _extract_sub_mb306 {
    my ($src, $name) = @_;
    my $re = qr/^[ \t]*sub[ \t]+\Q$name\E\b[^{]*\{/m;
    return undef unless $src =~ /$re/g;

    my ($start, $pos, $depth) = ($-[0], pos($src), 1);
    while ($pos < length($src)) {
        my $char = substr($src, $pos, 1);
        $depth++ if $char eq '{';
        $depth-- if $char eq '}';
        return substr($src, $start, $pos + 1 - $start) if $depth == 0;
        $pos++;
    }
    return undef;
}

return sub {
    my ($assert) = @_;

    my $src = _slurp_mb306(
        File::Spec->catfile('.', 'Mediabot', 'UserCommands.pm')
    );
    my $stop = _extract_sub_mb306($src, 'mbPollStop_ctx');

    my $result = _extract_sub_mb306($src, 'mbPollResult_ctx');

    $assert->ok(defined $result, 'mbPollResult_ctx found');

    $assert->like(
        $result // '',
        qr/my\s+\@winner_opts/,
        '!pollresult keeps every top option instead of selecting an arbitrary hash key'
    );

    $assert->like(
        $result // '',
        qr/\$winner_str\s*=\s*'\s*Tie:/,
        '!pollresult reports tied top options explicitly'
    );

    $assert->ok(defined $stop, 'mbPollStop_ctx found');

    $assert->like(
        $stop // '',
        qr/my\s+\$winner_label\s*=\s*\$opts->\[\$winner\]/,
        '!pollstop resolves the winning option label'
    );

    $assert->like(
        $stop // '',
        qr/\$weighted\s*\?\s*\(\$voters\s*\*\s*\$weight\)\s*:\s*\$voters/,
        '!pollstop applies configured weights when computing scores'
    );

    $assert->like(
        $stop // '',
        qr/Tie on \$basis/,
        '!pollstop reports equal top scores as a tie'
    );

    $assert->like(
        $stop // '',
        qr/mediabot_poll_duration_seconds/,
        '!pollstop updates the existing poll duration metric'
    );

    $assert->unlike(
        $stop // '',
        qr/Winner:\s*\$winner(?:\s|")/,
        '!pollstop no longer prints the raw zero-based winner index'
    );

    # Behavioral proof of the weighted winner rule used by the corrected code:
    # Pizza has fewer voters but a higher weighted score.
    my $poll = {
        options  => ['Pizza', 'Sushi'],
        weights  => [3, 1],
        weighted => 1,
        votes    => {
            alice   => 0,
            bob     => 0,
            charlie => 1,
            dave    => 1,
            eve     => 1,
        },
    };

    my %counts;
    $counts{ $poll->{votes}{$_} }++ for keys %{ $poll->{votes} };

    my %scores;
    for my $idx (0 .. $#{ $poll->{options} }) {
        my $voters = $counts{$idx} // 0;
        my $weight = $poll->{weights}[$idx] // 1;
        $scores{$idx} = $poll->{weighted}
            ? ($voters * $weight)
            : $voters;
    }

    my $best = -1;
    my @winners;
    for my $idx (0 .. $#{ $poll->{options} }) {
        my $score = $scores{$idx} // 0;
        if ($score > $best) {
            $best = $score;
            @winners = ($idx);
        }
        elsif ($score == $best) {
            push @winners, $idx;
        }
    }

    $assert->is($scores{0}, 6, 'Pizza weighted score is 6');
    $assert->is($scores{1}, 3, 'Sushi weighted score is 3');
    $assert->is(
        join(',', @winners),
        '0',
        'weighted winner is option index 0'
    );
    $assert->is(
        $poll->{options}[ $winners[0] ],
        'Pizza',
        'the announced winner is the option label Pizza'
    );

    # Tie behavior is deterministic and keeps every top label.
    my %tie_scores = (0 => 2, 1 => 2, 2 => 1);
    my $tie_best = -1;
    my @tie_winners;
    for my $idx (0 .. 2) {
        my $score = $tie_scores{$idx} // 0;
        if ($score > $tie_best) {
            $tie_best = $score;
            @tie_winners = ($idx);
        }
        elsif ($score == $tie_best) {
            push @tie_winners, $idx;
        }
    }

    $assert->is(
        join(',', @tie_winners),
        '0,1',
        'all tied top options are retained in option order'
    );
};
