# t/cases/65_channel_object_db_safety.t
# =============================================================================
# Static regression checks for Mediabot::Channel DB safety.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_channel_object_safety {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_channel_object_safety {
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

    my $src = _slurp_channel_object_safety(File::Spec->catfile('.', 'Mediabot', 'Channel.pm'));

    $assert->ok(
        $src =~ /sub _execute_update/,
        'Channel.pm has shared _execute_update helper'
    );

    my $helper = _extract_sub_channel_object_safety($src, '_execute_update');

    $assert->ok(
        $helper =~ /unless \(\$sth\)/,
        '_execute_update handles prepare failure'
    );

    $assert->ok(
        $helper =~ /SQL prepare error/,
        '_execute_update logs prepare failure'
    );

    $assert->ok(
        $helper =~ /unless \(\$sth->execute\(\@\{\$binds \|\| \[\]\}\)\)/,
        '_execute_update handles execute failure'
    );

    $assert->ok(
        $helper =~ /\$sth->finish;\s*return 0;/s,
        '_execute_update finishes statement on execute failure'
    );

    for my $setter (qw(set_topic set_tmdb_lang set_key set_description set_chanmode set_auto_join)) {
        my $func = _extract_sub_channel_object_safety($src, $setter);

        $assert->ok(
            $func =~ /_execute_update/,
            "$setter uses shared safe update helper"
        );

        $assert->ok(
            $func =~ /return \$ok \? 1 : 0;/,
            "$setter returns explicit success boolean"
        );
    }

    for my $getter (qw(get_user_level get_user_info exists_in_db create_in_db)) {
        my $func = _extract_sub_channel_object_safety($src, $getter);

        $assert->ok(
            $func =~ /unless \(\$sth\)/,
            "$getter handles prepare failure"
        );

        $assert->ok(
            $func =~ /SQL prepare error/,
            "$getter logs prepare failure"
        );

        $assert->ok(
            $func =~ /unless \(\$sth->execute/,
            "$getter handles execute failure"
        );

        $assert->ok(
            $func =~ /\$sth->finish;\s*return/s,
            "$getter finishes statement before returning on execute failure"
        );
    }

    my $create = _extract_sub_channel_object_safety($src, 'create_in_db');
    $assert->ok(
        $create =~ /\$self->\{dbh\}->last_insert_id/,
        'create_in_db uses dbh last_insert_id after statement finish'
    );
};
