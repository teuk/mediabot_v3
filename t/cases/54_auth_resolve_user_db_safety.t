# t/cases/54_auth_resolve_user_db_safety.t
# =============================================================================
# Static regression checks for Auth::_resolve_user DB safety.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_auth_resolve_user {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_auth_resolve_user {
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

    my $src     = _slurp_auth_resolve_user(File::Spec->catfile('.', 'Mediabot', 'Auth.pm'));
    my $resolve = _extract_sub_auth_resolve_user($src, '_resolve_user');
    my $fetch   = _extract_sub_auth_resolve_user($src, '_fetch_hostmasks');
    my $helper  = _extract_sub_auth_resolve_user($src, '_fetch_user_row');

    $assert->ok(
        $src =~ /sub _fetch_user_row/,
        'Auth has _fetch_user_row helper'
    );

    $assert->ok(
        $resolve =~ /\$self->_fetch_user_row/,
        '_resolve_user delegates DB reads to _fetch_user_row'
    );

    $assert->ok(
        $helper =~ /unless \(\$sth\)/,
        '_fetch_user_row handles prepare failure'
    );

    $assert->ok(
        $helper =~ /unless \(\$sth->execute\(\$value\)\)/,
        '_fetch_user_row handles execute failure'
    );

    $assert->ok(
        $helper =~ /\$sth->finish;\s*return \(undef, "execute_failed:\$label"\);/s,
        '_fetch_user_row finishes statement on execute failure'
    );

    $assert->ok(
        $helper =~ /\$sth->finish;\s*return \(undef, "not_found:\$label"\)/s,
        '_fetch_user_row finishes statement before not_found return'
    );

    $assert->ok(
        $fetch =~ /unless \(\$sth\)/,
        '_fetch_hostmasks handles prepare failure'
    );

    $assert->ok(
        $fetch =~ /unless \(\$sth->execute\(\$id_user\)\)/,
        '_fetch_hostmasks handles execute failure'
    );

    $assert->ok(
        $fetch =~ /\$sth->finish;\s*return '';/s,
        '_fetch_hostmasks finishes statement on execute failure'
    );

    $assert->ok(
        $fetch =~ /\$sth->finish;\s*return join\(',', \@masks\);/s,
        '_fetch_hostmasks finishes statement before final return'
    );

    $assert->ok(
        $resolve !~ /my \$sth = \$dbh->prepare/,
        '_resolve_user no longer performs raw prepare calls directly'
    );
};
