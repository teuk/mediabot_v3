# MB745 — the first-party playful pack keeps the six command contracts bounded.

use strict;
use warnings;
use utf8;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib", "$Bin/../..", "$Bin/../../plugins/playful-v3/lib";
}

return sub {
    my ($assert) = @_;
    require Mediabot::PluginContext;
    require Mediabot::Plugin::InvocationV3;
    require Playful;

    my $authority = Mediabot::PluginContext->new(
        plugin => 'playful-v3',
        requested => [qw(irc.reply irc.notice)],
        granted => [qw(irc.reply irc.notice)]);
    my $plugin = Mediabot::Plugin::Playful->new(context => $authority);
    $plugin->{rng} = 42;

    my (@replies, @notices);
    my $invoke = sub {
        my ($command, $args) = @_;
        return Mediabot::Plugin::InvocationV3->new(
            nick => 'Tangy', channel => '#development', command => $command,
            args => $args, source => 'public', is_private => 0,
            authority => $authority, activation => 'on',
            config => { language => 'fr' },
            reply_sink => sub { push @replies, $_[0]; 1 },
            notice_sink => sub { push @notices, $_[0]; 1 },
        );
    };

    $plugin->command_abbrev($authority, $invoke->('abbrev', [qw(quiet little channel)]));
    $assert->is($replies[-1], 'Tangy: QLC (3 word(s))',
        'abbrev preserves the compact acronym contract');

    $plugin->command_morse($authority, $invoke->('morse', ['SOS']));
    $assert->is($replies[-1], '... --- ...',
        'morse keeps the expected alphabet mapping');

    $plugin->command_choose($authority,
        $invoke->('choose', ['tea', '|', 'coffee', '|', 'tea']));
    $assert->like($replies[-1], qr/Tangy: I choose\.\.\. (?:tea|coffee)!/,
        'choose returns one deduplicated option');
    $assert->like($notices[-1], qr/duplicate option/,
        'choose reports duplicate removal privately');

    $plugin->command_flip($authority, $invoke->('flip', ['3']));
    $assert->like($replies[-1], qr/flipped 3 coins: [HT]{3}/,
        'flip supports the bounded multi-flip form');
    $plugin->command_flip($authority, $invoke->('flip', ['stats']));
    $assert->like($replies[-1], qr/3 total\z/,
        'flip maintains channel-local statistics');

    $plugin->command_roll($authority, $invoke->('roll', ['1d20', '+2', 'adv']));
    $assert->like($replies[-1], qr/rolled 1d20 \(adv\).*→/,
        'roll preserves modifier and advantage rendering');
    $plugin->command_roll($authority, $invoke->('roll', ['history']));
    $assert->like($replies[-1], qr/^Last rolls:/,
        'roll retains a bounded channel history');

    $plugin->command_8ball($authority,
        $invoke->('8ball', ['Est-ce', 'raisonnable', '?']));
    $assert->like($replies[-1], qr/\[8ball\].*Tangy:/,
        '8ball emits one language-scoped answer');

    $plugin->command_morse($authority, $invoke->('morse', ['x' x 81]));
    $assert->like($notices[-1], qr/max 80 chars/,
        'morse rejects oversized input through the notice sink');
};
