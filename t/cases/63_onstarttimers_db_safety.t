# t/cases/63_onstarttimers_db_safety.t
# =============================================================================
# Static regression checks for DBCommands::onStartTimers DB safety.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_onstarttimers_safety {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_onstarttimers_safety {
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

    my $src  = _slurp_onstarttimers_safety(File::Spec->catfile('.', 'Mediabot', 'DBCommands.pm'));
    my $func = _extract_sub_onstarttimers_safety($src, 'onStartTimers');

    $assert->ok(
        $func =~ /SELECT id_timers, name, duration, command FROM TIMERS/,
        'onStartTimers keeps timer startup query'
    );

    $assert->ok(
        $func =~ /unless \(\$sth\)/,
        'onStartTimers handles prepare failure'
    );

    $assert->ok(
        $func =~ /onStartTimers\(\) SQL prepare error/,
        'onStartTimers logs prepare failure'
    );

    $assert->ok(
        $func =~ /unless \(\$sth->execute\(\)\)/,
        'onStartTimers handles execute failure'
    );

    $assert->ok(
        $func =~ /onStartTimers\(\) SQL execute error/,
        'onStartTimers logs execute failure'
    );

    $assert->ok(
        $func =~ /\$sth->finish;\s*%\{\$self->\{hTimers\}\} = %hTimers;\s*return 0;/s,
        'onStartTimers finishes statement and clears timers on execute failure'
    );

    $assert->ok(
        $func =~ /next unless defined\(\$duration\) && \$duration =~ \/\^\\d\+\$\/ && \$duration > 0;/,
        'onStartTimers skips invalid timer duration'
    );

    $assert->ok(
        $func =~ /Timer \$name skipped: bot not connected to IRC/,
        'onStartTimers keeps disconnected IRC skip behavior'
    );

    $assert->ok(
        $func =~ /\$sth->finish;\s*if \(\$i\)/s,
        'onStartTimers finishes statement before final reporting'
    );

    $assert->ok(
        $func =~ /%\{\$self->\{hTimers\}\} = %hTimers;\s*return \$i;/s,
        'onStartTimers stores timers and returns count'
    );
};
