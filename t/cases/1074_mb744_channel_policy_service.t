# MB744 — per-channel off/observe/on policy with IRC casemapping.

use strict;
use warnings;
use utf8;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib", "$Bin/../..";
}

return sub {
    my ($assert) = @_;

    require Mediabot::Plugin::ConfigSchemaV3;
    require Mediabot::Plugin::ChannelPolicyV3;

    my $schema = Mediabot::Plugin::ConfigSchemaV3->new(schema => {
        label => { type => 'string', default => 'quiet', max_length => 20 },
        limit => { type => 'integer', default => 1, minimum => 0, maximum => 4 },
    });
    my $policy = Mediabot::Plugin::ChannelPolicyV3->new(schema => $schema);

    my $initial = $policy->policy_for('#i/o');
    $assert->is($initial->{mode}, 'off',
        'an unknown channel is off by default');
    $assert->is($initial->{config}{label}, 'quiet',
        'off policy still has a deterministic typed default snapshot');

    $policy->set('#Room[One]', mode => 'observe',
        config => { label => 'shadow', limit => 2 });
    my $folded = $policy->policy_for('#room{one}');
    $assert->is($folded->{mode}, 'observe',
        'RFC1459-equivalent channel spellings share one policy');
    $assert->is($folded->{config}{limit}, 2,
        'observe policy carries its effective configuration');

    $policy->set('#room{one}', mode => 'on');
    $assert->is($policy->policy_for('#ROOM[ONE]')->{mode}, 'on',
        'mode updates preserve the same canonical channel entry');
    $assert->is($policy->count, 1,
        'casemapped updates do not duplicate channel state');

    $policy->set('#off', mode => 'off', config => {});
    my @active = $policy->active_policies;
    $assert->is(scalar @active, 1,
        'active view excludes explicit off entries');
    $active[0]{config}{label} = 'mutated';
    $assert->is($policy->policy_for('#room{one}')->{config}{label}, 'shadow',
        'returned policies cannot mutate core-owned state');

    my $ok = eval { $policy->set('not-a-channel', mode => 'on'); 1 };
    $assert->like($@ // '', qr/invalid policy channel/,
        'non-channel scope is rejected');
    $ok = eval { $policy->set('#i/o', mode => 'maybe'); 1 };
    $assert->like($@ // '', qr/must be off, observe or on/,
        'unknown activation mode is rejected');

    $assert->is($policy->reset('#ROOM[ONE]'), 1,
        'policy reset follows the same IRC casemap');
    $assert->is($policy->policy_for('#room{one}')->{mode}, 'off',
        'reset returns the channel to fail-closed default');
};
