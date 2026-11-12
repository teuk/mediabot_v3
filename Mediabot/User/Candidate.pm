package Mediabot::User::Candidate;
use strict;
use warnings;

# Streaming selection only. The caller owns the cursor lifetime, matching
# implementation and authentication effects. Keep first row on equal score.
sub select_best {
    my ($sth, $fullmask, $host, $match) = @_;
    my $best_row;
    my $best_reason = '';
    my $best_score  = -1;

    while (my $row = $sth->fetchrow_hashref) {
        my $matched = 0;
        my $reason  = '';
        my $score   = -1;

        my ($mask_ok, $matched_mask, undef, $mask_score) = $match->($row, $fullmask);
        if ($mask_ok) {
            $matched = 1;
            $reason  = "hostmask:$matched_mask";
            $score   = $mask_score;
        }
        else {
            my $db_nick = lc($row->{nickname} // '');

            if ($host =~ /(^|\.)users\.undernet\.org\z/i) {
                my ($leftmost) = split(/\./, $host, 2);
                if (defined $leftmost && $leftmost ne '' && $db_nick ne '' && lc($leftmost) eq $db_nick) {
                    $matched = 1;
                    $reason  = "undernet_cloak";
                    $score   = 0;
                }
            }
        }

        next unless $matched;

        if ($score > $best_score) {
            $best_row    = { %$row };
            $best_reason = $reason;
            $best_score  = $score;
        }
    }

    return ($best_row, $best_reason, $best_score);
}

1;
