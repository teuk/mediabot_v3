# t/cases/77_chanset_list_db_safety.t
# =============================================================================
# Static regression checks for getIdChansetList DB safety.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_chanset_list_safety {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_getidchansetlist {
    my ($src) = @_;

    my $start = index($src, "sub getIdChansetList");
    die "sub getIdChansetList not found" if $start < 0;

    my $next = index($src, "\n\n# Retrieve the ID of a channel set from CHANNEL_SET table for a given channel and chanset list ID", $start);
    die "next marker after getIdChansetList not found" if $next < 0;

    return substr($src, $start, $next - $start);
}

return sub {
    my ($assert) = @_;

    my $src  = _slurp_chanset_list_safety(File::Spec->catfile('.', 'Mediabot', 'Helpers.pm'));
    my $func = _extract_getidchansetlist($src);

    $assert->ok(
        $func =~ /SELECT id_chanset_list FROM CHANSET_LIST WHERE chanset=\?/,
        'getIdChansetList keeps exact chanset lookup'
    );

    $assert->ok(
        $func =~ /unless \(\$sth\)/,
        'getIdChansetList handles prepare failure'
    );

    $assert->ok(
        $func =~ /getIdChansetList\(\) SQL prepare error/,
        'getIdChansetList logs prepare failure'
    );

    $assert->ok(
        $func =~ /unless \(\$sth->execute\(\$sChansetValue\)\)/,
        'getIdChansetList handles execute failure'
    );

    $assert->ok(
        $func =~ /getIdChansetList\(\) SQL execute error/,
        'getIdChansetList logs execute failure'
    );

    $assert->ok(
        $func =~ /\$sth->finish;\s*return undef;/s,
        'getIdChansetList finishes statement on execute failure'
    );

    $assert->ok(
        $func =~ /my \$id_chanset_list;/,
        'getIdChansetList stores result before returning'
    );

    $assert->ok(
        $func =~ /\$sth->finish;\s*return \$id_chanset_list;/s,
        'getIdChansetList finishes statement before final return'
    );

    $assert->ok(
        $func !~ /if \(!\$sth->execute/,
        'getIdChansetList no longer executes without prepare guard'
    );
};
