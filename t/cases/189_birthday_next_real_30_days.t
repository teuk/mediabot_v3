# t/cases/189_birthday_next_real_30_days.t
# =============================================================================
# Regression checks for birthday next.
#
# birthday next should use a real rolling 30-day window, including year wrap,
# instead of a simple MM-DD string comparison.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_189 {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_body_189 {
    my ($src, $sub_name) = @_;

    my $start_re = qr/^sub\s+\Q$sub_name\E\s*\{/m;
    return undef unless $src =~ /$start_re/g;

    my $start = pos($src);
    my $depth = 1;
    my $pos   = $start;
    my $len   = length($src);

    while ($pos < $len) {
        my $char = substr($src, $pos, 1);

        if ($char eq '{') {
            $depth++;
        }
        elsif ($char eq '}') {
            $depth--;

            if ($depth == 0) {
                return substr($src, $start, $pos - $start);
            }
        }

        $pos++;
    }

    return undef;
}

return sub {
    my ($assert) = @_;

    my $src = _slurp_189(
        File::Spec->catfile('.', 'Mediabot', 'UserCommands.pm')
    );

    my $next_body = _extract_sub_body_189($src, '_birthday_next_ctx');
    my $add_body  = _extract_sub_body_189($src, '_birthday_add_ctx');

    $assert->ok(defined $next_body, '_birthday_next_ctx body found');
    $assert->ok(defined $add_body,  '_birthday_add_ctx body found');

    $assert->like(
        $src,
        qr/use Time::Local qw\(timegm\);/,
        'UserCommands imports Time::Local for date calculations'
    );

    for my $helper (qw(_birthday_valid_date _birthday_mmdd_from_value _birthday_days_ahead)) {
        $assert->like(
            $src,
            qr/sub \Q$helper\E/,
            "$helper helper exists"
        );
    }

    $assert->like(
        $add_body // '',
        qr/_birthday_valid_date\(\$check_year, \$m, \$d\)/,
        'birthday add validates real calendar dates'
    );

    $assert->like(
        $next_body // '',
        qr/my \$window_days = 30;/,
        'birthday next defines a 30-day window'
    );

    $assert->like(
        $next_body // '',
        qr/my \$days_ahead = _birthday_days_ahead\(\$month, \$day, \$now\);/,
        'birthday next computes days ahead'
    );

    $assert->like(
        $next_body // '',
        qr/next if \$days_ahead > \$window_days;/,
        'birthday next filters birthdays outside the 30-day window'
    );

    $assert->like(
        $next_body // '',
        qr/\$a->\{days_ahead\} <=> \$b->\{days_ahead\}/,
        'birthday next sorts by days ahead'
    );

    $assert->like(
        $next_body // '',
        qr/Upcoming birthdays in the next \$window_days days:/,
        'birthday next reports the real window'
    );

    $assert->like(
        $next_body // '',
        qr/\$u->\{days_ahead\} == 0\s+\? 'today'\s+:\s+"in \$u->\{days_ahead\}d"/s,
        'birthday next displays today/in-N-days labels'
    );

    $assert->unlike(
        $next_body // '',
        qr/string comparison works for MM-DD/,
        'birthday next no longer relies on old string-comparison comment'
    );

    $assert->unlike(
        $next_body // '',
        qr/\$mmdd ge \$today/,
        'birthday next no longer uses MM-DD string comparison as its window'
    );
};
