# t/cases/82_chanlist_aliases.t
# =============================================================================
# Static regression checks for chanlist aliases.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_chanlist_aliases {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    my $src = _slurp_chanlist_aliases(File::Spec->catfile('.', 'Mediabot', 'Mediabot.pm'));

    my $chanlist_count = () = $src =~ /^\s*chanlist\s*=>\s*sub\s*\{\s*channelList_ctx\(\$ctx\)\s*\},/mg;
    my $channels_count = () = $src =~ /^\s*channels\s*=>\s*sub\s*\{\s*channelList_ctx\(\$ctx\)\s*\},/mg;
    my $channellist_count = () = $src =~ /^\s*channellist\s*=>\s*sub\s*\{\s*channelList_ctx\(\$ctx\)\s*\},/mg;

    $assert->ok(
        $chanlist_count >= 1,
        'chanlist dispatch exists'
    );

    $assert->ok(
        $channels_count == $chanlist_count,
        'channels alias exists everywhere chanlist exists'
    );

    $assert->ok(
        $channellist_count == $chanlist_count,
        'channellist alias exists everywhere chanlist exists'
    );

    $assert->ok(
        $src =~ /^\s*channels\s*=>\s*sub\s*\{\s*channelList_ctx\(\$ctx\)\s*\},/m,
        'channels dispatches to channelList_ctx'
    );

    $assert->ok(
        $src =~ /^\s*channellist\s*=>\s*sub\s*\{\s*channelList_ctx\(\$ctx\)\s*\},/m,
        'channellist dispatches to channelList_ctx'
    );
};
