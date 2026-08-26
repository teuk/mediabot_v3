# t/cases/936_mb701_wit_runtime_arm_config.t
# =============================================================================
# MB701-D-C — explicit runtime sender arm config remains default-off/fail-closed.
# =============================================================================

use strict;
use warnings;
use utf8;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use Mediabot::AI::ConversationSender;

return sub {
    my ($assert) = @_;

    my $sample = do {
        open my $fh, '<:encoding(UTF-8)', "$Bin/../../mediabot.sample.conf"
            or die "open sample config: $!";
        local $/;
        <$fh>;
    };
    my $arm_key_count = () = ($sample =~ /^WIT_SEND_ARMED=0$/mg);
    $assert->is($arm_key_count, 1,
        'mb701-936: sample config defines WIT_SEND_ARMED=0 exactly once');

    my $main = do {
        open my $fh, '<:encoding(UTF-8)', "$Bin/../../mediabot.pl"
            or die "open mediabot.pl: $!";
        local $/;
        <$fh>;
    };

    $assert->like($main, qr/sub _wit_sync_sender_arm;/,
        'mb701-936: runtime declares a dedicated arm synchronization helper');
    $assert->like($main, qr/sub _wit_sync_sender_arm \{/,
        'mb701-936: runtime defines the dedicated arm synchronization helper');
    $assert->like($main,
        qr/get_int\(\s*'main\.WIT_SEND_ARMED',\s*default\s*=>\s*0,\s*min\s*=>\s*0,\s*max\s*=>\s*1,/s,
        'mb701-936: arm config is bounded integer 0..1 with default OFF');
    $assert->like($main,
        qr/_wit_sync_sender_arm\(\$mediabot, \$mediabot->\{wit_sender\}\);.*?->attempt_send\s*\(/s,
        'mb701-936: sender arm state is synchronized immediately before each attempt');

    my ($sync) = $main =~ /(sub _wit_sync_sender_arm \{.*?\n\})/s;
    $assert->ok(defined($sync),
        'mb701-936: arm synchronization helper is extractable');
    $assert->like($sync // q{}, qr/->arm\s*\(\)/,
        'mb701-936: explicit config ON can arm the dedicated sender');
    $assert->like($sync // q{}, qr/->disarm\s*\(\)/,
        'mb701-936: config OFF explicitly disarms the sender');
    $assert->like($sync // q{}, qr/unless \(\$ok\).*?->disarm\s*\(\)/s,
        'mb701-936: synchronization exception path fails closed by disarming');
    $assert->unlike($sync // q{}, qr/botPrivmsg|botNotice|send_message|do_PRIVMSG/,
        'mb701-936: arm synchronization helper owns no IRC delivery primitive');

    # The runtime uses Conf->get_int with a safe default and hard 0..1 bounds.
    # Existing Config::Simple behavior is covered by the configuration test suite;
    # this contract keeps D-C focused on the new Wit wiring.

    my $calls = 0;
    my $sender = Mediabot::AI::ConversationSender->new(
        send_cb => sub { $calls++; return 1; },
    );
    $assert->is($sender->is_armed(), 0,
        'mb701-936: sender remains independently default-disarmed');
    $sender->arm();
    $assert->is($sender->is_armed(), 1,
        'mb701-936: explicit arm transition works');
    $sender->disarm();
    $assert->is($sender->is_armed(), 0,
        'mb701-936: explicit disarm transition is immediate');
    $assert->is($calls, 0,
        'mb701-936: arm/disarm transitions alone never call the transport');
};
