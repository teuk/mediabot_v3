# MB767 — quotes-v3 is the first ledger-backed controlled promotion.

use strict;
use warnings;
use utf8;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib", "$Bin/../..";
}

use JSON::PP ();

sub slurp_1138 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "$path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;
    my $contract = JSON::PP->new->decode(
        slurp_1138('plugins/API_V3_CONTRACT.json'));
    my $history = $contract->{development_promotion_history};
    my ($promotion) = grep {
        ($_->{milestone} // '') eq 'MB767'
    } @{ $history || [] };
    my $manifest = JSON::PP->new->decode(
        slurp_1138('plugins/quotes-v3/plugin.json'));

    $assert->is($contract->{milestone}, 'MB781',
        'machine contract advances while retaining quote promotion evidence');
    $assert->ok(ref($promotion) eq 'HASH',
        'quote promotion remains in machine-readable history');
    $assert->is($promotion->{milestone}, 'MB767',
        'historical development promotion remains versioned');
    $assert->is($promotion->{package}, 'quotes-v3',
        'quotes-v3 is the promoted package');
    $assert->is($promotion->{channel}, '#test',
        'promotion is limited to the development channel');
    $assert->is($promotion->{mode}, 'on',
        'accepted policy is authoritative on');
    $assert->is($promotion->{scope}, 'single development channel',
        'promotion scope is deliberately narrow');
    $assert->like($promotion->{evidence},
        qr/observe.*add.*view.*delete.*recall.*cleanup/i,
        'promotion evidence covers parity, mutation and cleanup');
    $assert->is($promotion->{persistent_operator_state}, JSON::PP::true,
        'accepted operator state is persistent');
    $assert->like($promotion->{restart_behavior},
        qr/exact grants.*enabled.*on policy/i,
        'restart proof restores exact authority and lifecycle');
    $assert->like($promotion->{explicit_rollback},
        qr/policy off.*disable.*unload/i,
        'rollback remains explicit and bounded');
    $assert->is($promotion->{production_channels}, 0,
        'no production channel is promoted');

    $assert->is(ref($history), 'ARRAY',
        'prior promotions remain a machine-readable history');
    $assert->is($history->[0]{milestone}, 'MB764',
        'factoid promotion history is retained');
    $assert->is($history->[0]{package}, 'factoids-v3',
        'historical package remains explicit');

    $assert->is($manifest->{activation}{default}, 'off',
        'package source remains default-off');
    $assert->is(join(',', @{ $manifest->{capabilities} }),
        'data.quotes.read,data.quotes.write,irc.reply,irc.notice',
        'promotion grants exactly the four manifest capabilities');
    $assert->is(join(',', sort keys %{ $manifest->{commands} }),
        'halloffame,q,quote,quotecount,topquote',
        'all five quote commands are in the promoted package');

    my $guide = slurp_1138('docs/PLUGIN_V3_PROMOTION.md');
    my $pilot = slurp_1138('docs/QUOTE_COMMAND_V3_PILOT.md');
    my $readme = slurp_1138('plugins/quotes-v3/README.md');
    my $changelog = slurp_1138('CHANGELOG.md');
    $assert->like($guide,
        qr/policy quotes-v3 #test observe.*?policy quotes-v3 #test on/s,
        'promotion guide requires observe before on');
    $assert->like($guide,
        qr/restart.*?exact\s+grants.*?enabled lifecycle.*?`on` policy/is,
        'promotion guide requires the persistent restart proof');
    $assert->like($guide,
        qr/policy quotes-v3 #test off.*?disable quotes-v3.*?unload quotes-v3/s,
        'promotion guide preserves explicit rollback order');
    $assert->like($pilot,
        qr/MB767.*?persistent development promotion.*?no production channel/is,
        'quote pilot records the accepted development-only posture');
    $assert->like($readme,
        qr/MB767.*?boot ledger.*?default-off.*?no production channel/is,
        'package guide distinguishes persisted intent from source defaults');
    $assert->like($changelog, qr/MB767.*?quotes-v3/is,
        'changelog records the controlled quote promotion');
};
