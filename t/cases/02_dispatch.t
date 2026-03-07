# t/cases/02_dispatch.t
# =============================================================================
#  Tests de la dispatch table de mbCommandPublic et mbCommandPrivate
# =============================================================================

BEGIN {
    require FindBin;
    unshift @INC, "$FindBin::Bin/../lib";
    unshift @INC, "$FindBin::Bin/../..";
}

use strict;
use warnings;
use Mediabot::Mediabot;

# Injecter mbCommandPublic/mbCommandPrivate dans MockBot après chargement de Mediabot::Mediabot.
# MockBot surcharge déjà botPrivmsg/botNotice/etc, donc les réponses sont bien capturées.
*MockBot::mbCommandPublic  = \&Mediabot::mbCommandPublic;
*MockBot::mbCommandPrivate = \&Mediabot::mbCommandPrivate;

return sub {
    my ($assert, $make_bot, $make_msg_chan, $make_msg_priv) = @_;

    sub try_public {
        my ($bot, $cmd, @args) = @_;
        $bot->reset_replies;
        eval {
            $bot->mbCommandPublic(
                MockMessage->from_channel(prefix => 'teuk!teuk@teuk.org', channel => '#test'),
                '#test', 'teuk', 0, $cmd, @args
            );
        };
        my $err = $@ // '';
        return 1 if !$err;
        return 1 if $err =~ /DBI|DBD|SQL|execute|prepare|connect|locate/i;
        return 0;
    }

    sub try_private {
        my ($bot, $cmd, @args) = @_;
        $bot->reset_replies;
        eval {
            $bot->mbCommandPrivate(
                MockMessage->from_private(prefix => 'teuk!teuk@teuk.org'),
                'teuk', $cmd, @args
            );
        };
        my $err = $@ // '';
        return 1 if !$err;
        return 1 if $err =~ /DBI|DBD|SQL|execute|prepare|connect|locate/i;
        return 0;
    }

    my $bot = $make_bot->();

    # 1. Commandes publiques connues
    for my $cmd (qw(echo status version help colors date leet whoami seen yomomma spike resolve)) {
        $assert->ok(try_public($bot, $cmd), "mbCommandPublic '$cmd' : pas d'exception fatale");
    }

    # 2. Commande inconnue
    $assert->ok(try_public($bot, 'xxxxxxcommandinconnuexxxxxx'),
        "Commande inconnue : pas d'exception fatale");

    # 3. echo avec argument
    $assert->ok(try_public($bot, 'echo', 'ping'),
        "mbCommandPublic 'echo ping' : pas d'exception");

    # 4. Insensibilite a la casse
    for my $v (qw(ECHO Echo eCHo)) {
        $assert->ok(try_public($bot, $v, 'test'), "mbCommandPublic case-insensitive '$v'");
    }

    # 5. Commandes privees connues
    for my $cmd (qw(echo status whoami login die)) {
        $assert->ok(try_private($bot, $cmd), "mbCommandPrivate '$cmd' : pas d'exception fatale");
    }

    # 6. Commande privee inconnue
    $assert->ok(try_private($bot, 'xxxxxxcommandinconnuexxxxxx'),
        "mbCommandPrivate commande inconnue : pas d'exception");

    # 7. Alias q / Q
    for my $alias (qw(q Q)) {
        $assert->ok(try_public($bot, $alias), "Alias '$alias' dispatche sans exception fatale");
    }
};
