use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib", "$Bin/../..";
}

use Mediabot::Spark::Identity qw(is_known_bot_nick);
use Mediabot::AI::ConversationRuntimeState;

return sub {
    my ($assert) = @_;

    $assert->ok(is_known_bot_nick(
        nick => 'cOiN', configured_bot_nicks => 'Coin,RelayBot',
    ), 'mb739-1063: Coin ignore matching is case-insensitive');
    $assert->ok(is_known_bot_nick(
        nick => 'Game{Bot}', configured_bot_nicks => 'Game[Bot]',
    ), 'mb739-1063: dedicated ignore matching follows the IRC casemap');
    $assert->ok(!is_known_bot_nick(
        nick => 'Alice', configured_bot_nicks => 'Coin,RelayBot',
    ), 'mb739-1063: a human nick is not swallowed by the ignore list');

    # Connection-specific exclusions must distinguish ASCII and RFC identities.
    for my $case (
        ['ascii', 'Game{Bot}', 'Game[Bot]', 0],
        ['strict-rfc1459', 'Game{Bot}', 'Game[Bot]', 1],
        ['rfc1459', 'Game{Bot}', 'Game[Bot]', 1],
        ['ascii', 'Game~Bot', 'Game^Bot', 0],
        ['strict-rfc1459', 'Game~Bot', 'Game^Bot', 0],
        ['rfc1459', 'Game~Bot', 'Game^Bot', 1],
        ['ascii', 'cOiN', 'Coin', 1],
    ) {
        my ($mapping, $nick, $known, $expected) = @$case;
        for my $source (qw(bot_nick configured_bot_nicks)) {
            $assert->is(is_known_bot_nick(nick => $nick, $source => $known,
                casemapping => $mapping), $expected,
                "mb1256: $mapping $source distinguishes $nick / $known");
        }
    }
    my $state = Mediabot::AI::ConversationRuntimeState->new;
    my $matches = sub { is_known_bot_nick(nick => 'Nick{',
        configured_bot_nicks => 'Nick[', casemapping => $state->casemapping) };
    $assert->is($matches->(), 0, 'mb1256: pre-ISUPPORT identity stays conservative');
    $state->mark_connected;
    $state->update_isupport('CASEMAPPING=rfc1459');
    $assert->is($matches->(), 1, 'mb1256: negotiated equivalence is used');
    $state->update_isupport('CASEMAPPING=ascii');
    $assert->is($matches->(), 0, 'mb1256: changed mapping is effective immediately');
    $state->update_isupport('CASEMAPPING=rfc1459');
    $state->update_isupport('-CASEMAPPING');
    $assert->is($matches->(), 0, 'mb1256: removed mapping returns to conservative identity');
    $state->update_isupport('CASEMAPPING=rfc1459');
    $state->mark_disconnected;
    $state->mark_connected;
    $assert->is($matches->(), 0, 'mb1256: new connection cannot inherit old equivalences');
    $assert->ok(!is_known_bot_nick(nick => [], bot_nick => 'Coin', casemapping => 'ascii'),
        'mb1256: malformed nick still rejected');

    my $read = sub {
        my ($path) = @_;
        open my $fh, '<:encoding(UTF-8)', "$Bin/../../$path"
            or die "open $path: $!";
        local $/;
        return <$fh>;
    };
    my $main = $read->('mediabot.pl');
    $assert->is(scalar(() = $main =~ /casemapping => \$mediabot->\{wit_runtime_state\}\s*\? \$mediabot->\{wit_runtime_state\}->casemapping : 'ascii'/g), 2,
        'mb1256: both public identity decisions receive the connection mapping');
    my $sample = $read->('mediabot.sample.conf');
    my $doc = $read->('docs/WIT_QUIP.md');

    $assert->like($main,
        qr/my \$wit_ignore_nicks\s*=.*?main\.WIT_IGNORE_NICKS.*?my \$from_wit_ignored\s*=.*?from_bot\s*=>\s*\$from_wit_ignored/s,
        'mb739-1063: one ignored-bot decision covers Wit and Quip observation');
    $assert->like($main, qr/\$wit_ignore_nicks\s*=\s*'Coin'/,
        'mb739-1063: upgraded private configs default safely to Coin');
    $assert->is(scalar(() = $sample =~ /^WIT_IGNORE_NICKS=Coin$/mg), 1,
        'mb739-1063: sample configuration excludes Coin exactly once');
    $assert->like($doc, qr/Coin.*cannot trigger.*context/is,
        'mb739-1063: operator documentation explains the no-trigger/no-context boundary');
};
