# t/cases/67_timers_count_pagination.t
# =============================================================================
# Static regression checks for .timers count and pagination.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_timers_count_pagination {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_timers_count_pagination {
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

    my $src  = _slurp_timers_count_pagination(File::Spec->catfile('.', 'Mediabot', 'DBCommands.pm'));
    my $func = _extract_sub_timers_count_pagination($src, 'mbTimers_ctx');

    $assert->ok(
        $func =~ /SELECT name, duration, command FROM TIMERS ORDER BY name/,
        '.timers reads DB timers in stable order'
    );

    $assert->ok(
        $func =~ /unless \(\$sth\)/,
        '.timers handles prepare failure'
    );

    $assert->ok(
        $func =~ /mbTimers_ctx\(\) SQL prepare error/,
        '.timers logs prepare failure'
    );

    $assert->ok(
        $func =~ /unless \(\$sth->execute\(\)\)/,
        '.timers handles execute failure'
    );

    $assert->ok(
        $func =~ /\$sth->finish;\s*\$self->botNotice\(\$nick, "DB error while reading timers"\);/s,
        '.timers finishes statement on execute failure'
    );

    $assert->ok(
        $func =~ /my \@timer_lines;/,
        '.timers stores timer lines before output'
    );

    $assert->ok(
        $func =~ /my \$count = scalar\(\@timer_lines\);/,
        '.timers count is derived from collected timers'
    );

    my $count_increments = () = $func =~ /\$count\+\+/g;
    $assert->ok(
        $count_increments == 0,
        '.timers no longer increments count manually or twice per row'
    );

    $assert->ok(
        $func =~ /DB timers: \$count result\(s\)/,
        '.timers has summary line'
    );

    $assert->ok(
        $func =~ /timer\[%02d\]/,
        '.timers has numbered DB timer lines'
    );

    $assert->ok(
        $func =~ /Scheduler tasks: " \. scalar\(\@tasks\) \. " result\(s\)/,
        '.timers has scheduler summary line'
    );

    $assert->ok(
        $func =~ /schedule\[%02d\]/,
        '.timers has numbered scheduler lines'
    );

    $assert->ok(
        $func =~ /return \$count;/,
        '.timers returns actual DB timer count'
    );
};
