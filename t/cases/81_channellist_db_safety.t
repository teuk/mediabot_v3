# t/cases/81_channellist_db_safety.t
# =============================================================================
# Static regression checks for ChannelCommands::channelList_ctx DB safety.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_channellist_safety {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_channellist {
    my ($src) = @_;

    my $start = index($src, "sub channelList_ctx");
    die "sub channelList_ctx not found" if $start < 0;

    my $next = index($src, "\n\n# versionCheck() - sends version info in channel and alerts if update is available\nsub registerChannel", $start);
    die "next marker after channelList_ctx not found" if $next < 0;

    return substr($src, $start, $next - $start);
}

return sub {
    my ($assert) = @_;

    my $src  = _slurp_channellist_safety(File::Spec->catfile('.', 'Mediabot', 'ChannelCommands.pm'));
    my $func = _extract_channellist($src);

    my $count = () = $src =~ /^sub\s+channelList_ctx\s*\{/mg;
    $assert->ok(
        $count == 1,
        'there is exactly one channelList_ctx sub'
    );

    $assert->ok(
        $func =~ /unless \(\$dbh\)/,
        'channelList_ctx checks DB handle'
    );

    $assert->ok(
        $func =~ /FROM CHANNEL C/,
        'channelList_ctx keeps channel listing query'
    );

    $assert->ok(
        $func =~ /LEFT JOIN USER_CHANNEL UC ON UC\.id_channel = C\.id_channel/,
        'channelList_ctx keeps user count join'
    );

    $assert->ok(
        $func =~ /unless \(\$sth\)/,
        'channelList_ctx handles prepare failure'
    );

    $assert->ok(
        $func =~ /channelList_ctx\(\) SQL prepare error/,
        'channelList_ctx logs prepare failure'
    );

    $assert->ok(
        $func =~ /unless \(\$sth->execute\(\)\)/,
        'channelList_ctx handles execute failure'
    );

    $assert->ok(
        $func =~ /channelList_ctx\(\) SQL execute error/,
        'channelList_ctx logs execute failure'
    );

    $assert->ok(
        $func =~ /\$sth->finish;\s*botNotice\(\$self, \$nick, "Internal error \(query failed\)\."\);/s,
        'channelList_ctx finishes statement on execute failure'
    );

    $assert->ok(
        $func =~ /\$sth->finish;\s*unless \(\@items\)/s,
        'channelList_ctx finishes statement before output handling'
    );

    $assert->ok(
        $func =~ /chanlist\[%02d\]/,
        'channelList_ctx keeps paginated output'
    );

    $assert->ok(
        $func =~ /unless \(\$sth && \$sth->execute\(\)\).*?\$sth->finish if \$sth;/s,
        'channelList_ctx combined execute guard still finishes safely'
    );
};
