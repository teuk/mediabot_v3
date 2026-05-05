# t/cases/70_user_object_db_safety.t
# =============================================================================
# Static regression checks for Mediabot::User DB safety.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_user_object_safety {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_user_object_safety {
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

    my $src    = _slurp_user_object_safety(File::Spec->catfile('.', 'Mediabot', 'User.pm'));
    my $load   = _extract_sub_user_object_safety($src, 'load_level');
    my $create = _extract_sub_user_object_safety($src, 'create');

    $assert->ok(
        $src =~ /sub _log/,
        'User.pm has _log helper'
    );

    $assert->ok(
        $load =~ /unless \(\$sth\)/,
        'load_level handles prepare failure'
    );

    $assert->ok(
        $load =~ /unless \(\$sth->execute\(\$self->\{level_id\}\)\)/,
        'load_level handles execute failure'
    );

    $assert->ok(
        $load =~ /\$sth->finish;\s*return 0;/s,
        'load_level finishes statement on execute failure'
    );

    $assert->ok(
        $load =~ /\$sth->finish;\s*return \$loaded;/s,
        'load_level finishes statement before final return'
    );

    for my $label (
        'level SQL prepare error',
        'duplicate-check SQL prepare error',
        'user insert SQL prepare error',
        'hostmask SQL prepare error',
        'refetch SQL prepare error',
    ) {
        $assert->ok(
            index($create, $label) >= 0,
            "create handles $label"
        );
    }

    for my $label (
        'level SQL execute error',
        'duplicate-check SQL execute error',
        'Failed to insert user',
        'Failed to insert hostmask',
        'refetch SQL execute error',
    ) {
        $assert->ok(
            index($create, $label) >= 0,
            "create handles $label"
        );
    }

    $assert->ok(
        $create =~ /\$dbh->last_insert_id/,
        'create uses DB handle last_insert_id'
    );

    $assert->ok(
        $create =~ /mysql_insertid/,
        'create keeps mysql_insertid fallback'
    );

    $assert->ok(
        $create !~ /\$sth_insert->\{ Database \}->last_insert_id/,
        'create no longer uses statement Database handle for last_insert_id'
    );

    $assert->ok(
        $create =~ /\$hm->finish;/,
        'create finishes hostmask insert statement'
    );

    $assert->ok(
        $create =~ /\$sth_get->finish;\s*return undef unless \$row;/s,
        'create finishes refetch statement before row check'
    );
};
