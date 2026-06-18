# t/cases/68_timer_add_remove_db_safety.t
# =============================================================================
# Static regression checks for addtimer/remtimer DB consistency.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_timer_add_remove_safety {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_timer_add_remove_safety {
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

    my $src = _slurp_timer_add_remove_safety(File::Spec->catfile('.', 'Mediabot', 'DBCommands.pm'));
    my $add = _extract_sub_timer_add_remove_safety($src, 'mbAddTimer_ctx');
    my $rem = _extract_sub_timer_add_remove_safety($src, 'mbRemTimer_ctx');

    $assert->ok(
        $add =~ /SELECT 1 FROM TIMERS WHERE name = \? LIMIT 1/,
        'addtimer checks DB duplicate before insert'
    );

    $assert->ok(
        $add =~ /INSERT INTO TIMERS \(name, duration, command\) VALUES \(\?,\?,\?\)/,
        'addtimer inserts timer into DB'
    );

    $assert->ok(
        index($add, 'INSERT INTO TIMERS') < index($add, 'IO::Async::Timer::Periodic->new'),
        'addtimer inserts DB row before starting runtime timer'
    );

    $assert->ok(
        $add =~ /unless \(\$sth\)/,
        'addtimer handles prepare failure'
    );

    $assert->ok(
        $add =~ /unless \(\$sth->execute/,
        'addtimer handles execute failure'
    );

    $assert->ok(
        $add !~ /\$self->\{dbh\}->do/,
        'addtimer no longer uses dbh->do'
    );

    $assert->ok(
        $add !~ /eval\s*\{/,
        'addtimer no longer wraps DB writes in eval'
    );

    $assert->ok(
        $rem =~ /DELETE FROM TIMERS WHERE name = \?/,
        'remtimer deletes timer from DB'
    );

    $assert->ok(
        index($rem, 'DELETE FROM TIMERS') < index($rem, '$self->{loop}->remove'),
        'remtimer deletes DB row before removing runtime timer'
    );

    $assert->ok(
        $rem =~ /my \$rows = \$sth->rows;/,
        'remtimer checks deleted row count'
    );

    $assert->ok(
        $rem =~ /Timer \$name was running but not found in database/,
        'remtimer reports runtime/DB divergence'
    );

    $assert->ok(
        $rem !~ /\$self->\{dbh\}->do/,
        'remtimer no longer uses dbh->do'
    );

    $assert->ok(
        $rem !~ /eval\s*\{[^}]*?(?:DELETE FROM TIMERS|->prepare|->execute)/s,
        'remtimer does not wrap DB deletion in eval'
    );
};
