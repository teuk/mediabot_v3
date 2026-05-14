# t/cases/218_usercommands_poll_deadline.t
# =============================================================================
# Verify mbPoll_ctx sets a deadline and mbVote_ctx checks it (B7/fix).
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_218 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/; return <$fh>;
}

return sub {
    my ($assert) = @_;

    my $src = _slurp_218(File::Spec->catfile('.', 'Mediabot', 'UserCommands.pm'));

    $assert->like($src, qr/deadline.*time\(\).*\+/,
        'mbPoll_ctx sets a deadline based on time()');

    $assert->like($src, qr/Poll expired/,
        'mbVote_ctx handles expired poll');

    $assert->like($src, qr/sub mbPoll_ctx/,
        'mbPoll_ctx sub exists');

    $assert->like($src, qr/sub mbVote_ctx/,
        'mbVote_ctx sub exists');

    $assert->like($src, qr/sub mbPollResult_ctx/,
        'mbPollResult_ctx sub exists');

    $assert->like($src, qr/sub mbPollStop_ctx/,
        'mbPollStop_ctx sub exists');
};
