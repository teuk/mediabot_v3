# t/cases/37_topsay_pagination.t
# =============================================================================
# Static regression checks for topsay paginated output.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_topsay_pagination {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_topsay_pagination {
    my ($src, $name) = @_;

    my $start = index($src, "sub $name");
    die "sub $name not found" if $start < 0;

    my $brace = index($src, "{", $start);
    die "opening brace for $name not found" if $brace < 0;

    my $depth      = 0;
    my $in_single  = 0;
    my $in_double  = 0;
    my $in_comment = 0;
    my $escape     = 0;

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

    my $src  = _slurp_topsay_pagination(File::Spec->catfile('.', 'Mediabot', 'UserCommands.pm'));
    my $func = _extract_sub_topsay_pagination($src, 'userTopSay_ctx');

    $assert->ok(
        $func =~ /LIMIT 30/,
        'topsay keeps SQL LIMIT 30'
    );

    $assert->ok(
        $func =~ /CHANNEL_LOG\.nick LIKE \? ESCAPE '!'/,
        q{topsay nick filter uses MariaDB-safe ESCAPE '!'}
    );

    $assert->ok(
        $func =~ /\$target_nick_like =~ s\/!\/!!\/g/,
        'topsay escapes LIKE escape character'
    );

    $assert->ok(
        $func =~ /\$target_nick_like =~ s\/%\/!%\/g/,
        'topsay escapes percent wildcard literally'
    );

    $assert->ok(
        $func =~ /\$target_nick_like =~ s\/_\/!_\/g/,
        'topsay escapes underscore wildcard literally'
    );

    $assert->ok(
        $func =~ /execute\(\$chan, \$target_nick_like\)/,
        'topsay executes query with escaped nick pattern'
    );

    $assert->ok(
        $func =~ /Top sayings for \$target_nick on \$chan: \$count result\(s\), showing max 30/,
        'topsay has summary line'
    );

    $assert->ok(
        $func =~ /details sent by notice to \$nick/,
        'topsay avoids multi-line channel flood'
    );

    $assert->ok(
        $func =~ /my \$per_line = 3;/,
        'topsay paginates at 3 entries per line'
    );

    $assert->ok(
        $func =~ /topsay\[%02d\]/,
        'topsay detail lines are numbered'
    );

    $assert->ok(
        $func =~ /botNotice\(\$self, \$nick, \$line\);/,
        'topsay sends paginated details by notice'
    );

    $assert->ok(
        $func =~ /my \@skip_patterns/,
        'topsay keeps skip-pattern filtering'
    );

    $assert->ok(
        $func !~ /my \$maxLength = 300/,
        'topsay no longer uses old maxLength truncation'
    );

    $assert->ok(
        $func !~ /last if \$new_len >= \$maxLength/,
        'topsay no longer stops collecting results because one line is too long'
    );

    $assert->ok(
        $func !~ /my \$response\s+=\s+"\$target_nick: "/,
        'topsay no longer builds one huge response line'
    );
};
