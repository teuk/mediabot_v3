# MB765 — pure, reloadable channel conversation exclusion policy.

use strict;
use warnings;
use utf8;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib", "$Bin/../..";
}

{
    package MB765::Conf;

    sub new {
        my ($class, %values) = @_;
        return bless { values => \%values }, $class;
    }

    sub get {
        my ($self, $key) = @_;
        return $self->{values}{$key};
    }

    sub set {
        my ($self, $key, $value) = @_;
        $self->{values}{$key} = $value;
        return 1;
    }
}

return sub {
    my ($assert) = @_;

    require Mediabot::AI::ConversationExclusion;

    my $conf = MB765::Conf->new(
        'conversation.CHANNEL_BOTS' =>
            'radiocapsule:Balibalo+mediacaps+WarHawk|i/o:Coin',
        'conversation.CHANNEL_COMMANDS' =>
            'i/o:!bang+!pan+!reload+!shop+!inventory+!duckstats+!lastduck+!duckrank',
    );
    my $policy = Mediabot::AI::ConversationExclusion->new(conf => $conf);

    my $decision = $policy->classify_public_line(
        channel => '#RadioCapsule', nick => 'bALIBALO',
        bot_nick => 'mediabotv3', message => 'automated line',
    );
    $assert->ok($decision->{excluded},
        'declared bot matching uses the IRC casemap');
    $assert->is($decision->{reason}, 'declared_bot',
        'declared sender has the bounded sender reason');

    $decision = $policy->classify_public_line(
        channel => '#elsewhere', nick => 'Balibalo',
        bot_nick => 'mediabotv3', message => 'ordinary line',
    );
    $assert->ok(!$decision->{excluded},
        'channel declaration does not become a global ignore');

    for my $line ('Coin: score', 'Coin, score', '@Coin score', 'Coin score') {
        $decision = $policy->classify_public_line(
            channel => '#i/o', nick => 'player',
            bot_nick => 'nbot', message => $line,
        );
        $assert->is($decision->{reason}, 'bot_address',
            "direct Coin address is excluded: $line");
    }

    $decision = $policy->classify_public_line(
        channel => '#i/o', nick => 'player', bot_nick => 'nbot',
        message => 'on se retrouve dans un coin tranquille',
    );
    $assert->ok(!$decision->{excluded},
        'ordinary later occurrence of coin remains human conversation');

    for my $command (qw(
        !bang !pan !reload !shop !inventory !duckstats !lastduck !duckrank
    )) {
        $decision = $policy->classify_public_line(
            channel => '#i/o', nick => 'player', bot_nick => 'nbot',
            message => "$command optional arguments",
        );
        $assert->is($decision->{reason}, 'bot_command',
            "exact pyDuckHunt command is excluded: $command");
    }

    for my $line ('#quote 12', '!helpful text', 'je dis !bang plus tard') {
        $decision = $policy->classify_public_line(
            channel => '#i/o', nick => 'player', bot_nick => 'nbot',
            message => $line,
        );
        $assert->ok(!$decision->{excluded},
            "unrelated traffic stays visible: $line");
    }

    $decision = $policy->classify_public_line(
        channel => '#i/o', nick => 'nbot', bot_nick => 'nbot',
        message => 'echo-message payload',
    );
    $assert->is($decision->{reason}, 'declared_bot',
        'the live bot identity is always excluded from its own ingress');

    $conf->set('conversation.CHANNEL_BOTS', 'radiocapsule:NewRelay');
    $decision = $policy->classify_public_line(
        channel => '#radiocapsule', nick => 'Balibalo',
        bot_nick => 'mediabotv3', message => 'now visible',
    );
    $assert->ok(!$decision->{excluded},
        'configuration changes invalidate the compiled map');
    $decision = $policy->classify_public_line(
        channel => '#radiocapsule', nick => 'newrelay',
        bot_nick => 'mediabotv3', message => 'now excluded',
    );
    $assert->ok($decision->{excluded},
        'reloaded declaration takes effect without a new policy object');

    $conf->set('conversation.CHANNEL_BOTS', [
        'radiocapsule:ArrayRelay', 'i/o:ArrayCoin'
    ]);
    $decision = $policy->classify_public_line(
        channel => '#i/o', nick => 'arraycoin',
        bot_nick => 'nbot', message => 'array-backed config',
    );
    $assert->ok($decision->{excluded},
        'Config::Simple array values retain every channel clause');
};
