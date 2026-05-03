# t/cases/59_channel_lookup_db_safety.t
# =============================================================================
# Static regression checks for channel lookup DB safety.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_channel_lookup_safety {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_channel_lookup_safety {
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

    my $chan_src = _slurp_channel_lookup_safety(File::Spec->catfile('.', 'Mediabot', 'ChannelCommands.pm'));
    my $help_src = _slurp_channel_lookup_safety(File::Spec->catfile('.', 'Mediabot', 'Helpers.pm'));

    my $by_name = _extract_sub_channel_lookup_safety($chan_src, 'get_channel_by_name');
    my $logbot  = _extract_sub_channel_lookup_safety($help_src, 'logBotAction');
    my $chset   = _extract_sub_channel_lookup_safety($help_src, 'getIdChannelSet');

    for my $pair (
        [ $by_name, 'get_channel_by_name' ],
        [ $logbot,  'logBotAction' ],
        [ $chset,   'getIdChannelSet' ],
    ) {
        my ($func, $name) = @$pair;

        $assert->ok(
            $func =~ /unless \(\$sth\)/,
            "$name handles prepare failure"
        );

        $assert->ok(
            $func =~ /prepare error/,
            "$name logs prepare failure"
        );

        $assert->ok(
            $func =~ /unless \(\$sth->execute/,
            "$name handles execute failure"
        );

        $assert->ok(
            $func =~ /execute error/,
            "$name logs execute failure"
        );

        $assert->ok(
            $func =~ /\$sth->finish;\s*return/s,
            "$name finishes statement before returning on execute failure"
        );
    }

    $assert->ok(
        $by_name =~ /SELECT id_channel FROM CHANNEL WHERE name = \?/,
        'get_channel_by_name keeps exact channel lookup'
    );

    $assert->ok(
        $chset =~ /WHERE name = \? AND id_chanset_list = \?/,
        'getIdChannelSet keeps exact channel/chanset lookup'
    );

    $assert->ok(
        $logbot =~ /SQL insert prepare error/,
        'logBotAction handles insert prepare failure'
    );

    $assert->ok(
        $logbot =~ /SQL insert execute error/,
        'logBotAction handles insert execute failure'
    );

    $assert->ok(
        $logbot =~ /\$sth_insert->finish;\s*return;/s,
        'logBotAction finishes insert statement on execute failure'
    );

    $assert->ok(
        $logbot =~ /\$sth_insert->finish;\s*\$self->\{logger\}->log/s,
        'logBotAction finishes insert statement on success'
    );
};
