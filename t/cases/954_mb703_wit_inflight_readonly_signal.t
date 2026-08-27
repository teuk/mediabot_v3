# t/cases/954_mb703_wit_inflight_readonly_signal.t
# =============================================================================
# MB703-D — Spark may observe Wit inflight state through a tiny read-only API.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use Mediabot::AI::ConversationDryRun;

return sub {
    my ($assert) = @_;

    my $obj = bless {
        inflight => {
            '#busy' => 1,
        },
    }, 'Mediabot::AI::ConversationDryRun';

    $assert->is($obj->channel_inflight('#busy'), 1,
        'mb703-954: read-only Wit signal reports a busy channel');
    $assert->is($obj->channel_inflight('#idle'), 0,
        'mb703-954: read-only Wit signal reports an idle channel');
    $assert->is($obj->channel_inflight('#BUSY'), 1,
        'mb703-954: Wit inflight lookup is channel-case insensitive');

    my $ok = eval { $obj->channel_inflight('private'); 1 };
    $assert->ok(!$ok,
        'mb703-954: read-only signal rejects private/non-channel targets');
};
