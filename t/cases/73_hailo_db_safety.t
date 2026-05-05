# t/cases/73_hailo_db_safety.t
# =============================================================================
# Static regression checks for Hailo DB safety.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_hailo_safety {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_hailo_safety {
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

    my $src = _slurp_hailo_safety(File::Spec->catfile('.', 'Mediabot', 'Hailo.pm'));

    for my $subname (
        qw(
            is_hailo_excluded_nick
            hailo_ignore_ctx
            hailo_unignore_ctx
            get_hailo_channel_ratio
            set_hailo_channel_ratio
        )
    ) {
        my $func = _extract_sub_hailo_safety($src, $subname);

        $assert->ok(
            $func =~ /unless \(\$sth\)/,
            "$subname handles prepare failure"
        );

        $assert->ok(
            $func =~ /prepare error/,
            "$subname logs prepare failure"
        );

        $assert->ok(
            $func =~ /unless \(\$sth->execute/,
            "$subname handles execute failure"
        );

        $assert->ok(
            $func =~ /execute error/,
            "$subname logs execute failure"
        );

        $assert->ok(
            $func =~ /\$sth->finish;\s*return/s,
            "$subname finishes statement before returning on execute failure"
        );
    }

    my $excluded = _extract_sub_hailo_safety($src, 'is_hailo_excluded_nick');
    $assert->ok(
        $excluded =~ /SELECT 1 FROM HAILO_EXCLUSION_NICK WHERE nick = \?/,
        'is_hailo_excluded_nick keeps exact nick lookup'
    );

    my $get_ratio = _extract_sub_hailo_safety($src, 'get_hailo_channel_ratio');
    $assert->ok(
        $get_ratio =~ /WHERE CHANNEL\.name = \?/,
        'get_hailo_channel_ratio keeps exact channel lookup'
    );

    my $set_ratio = _extract_sub_hailo_safety($src, 'set_hailo_channel_ratio');
    $assert->ok(
        $set_ratio =~ /\$self->\{channels\}\{\$sChannel\} \|\| \$self->\{channels\}\{lc\(\$sChannel\)\}/,
        'set_hailo_channel_ratio supports case-insensitive channel object lookup'
    );

    $assert->ok(
        $set_ratio =~ /INSERT INTO HAILO_CHANNEL \(id_channel, ratio\) VALUES \(\?, \?\)/,
        'set_hailo_channel_ratio keeps insert path'
    );

    $assert->ok(
        $set_ratio =~ /UPDATE HAILO_CHANNEL SET ratio = \? WHERE id_channel = \?/,
        'set_hailo_channel_ratio keeps update path'
    );
};
