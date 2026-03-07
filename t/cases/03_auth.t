# t/cases/03_auth.t
# =============================================================================
#  Tests du mécanisme d'authentification et de contrôle des droits
# =============================================================================

BEGIN {
    require FindBin;
    unshift @INC, "$FindBin::Bin/../lib";
    unshift @INC, "$FindBin::Bin/../..";
}

use strict;
use warnings;
use Mediabot::Mediabot;
use Mediabot::Context;

# Injecter mbCommandPublic/mbCommandPrivate dans MockBot
*MockBot::mbCommandPublic  = \&Mediabot::mbCommandPublic;
*MockBot::mbCommandPrivate = \&Mediabot::mbCommandPrivate;

# Rediriger les appels de sortie IRC du package Mediabot vers MockBot
# Redirection silencieuse (prototype mismatch attendu)
{
    no warnings qw(redefine prototype);
    *Mediabot::botNotice  = \&MockBot::botNotice;
    *Mediabot::botPrivmsg = \&MockBot::botPrivmsg;
}

# Garantir que deny() dans Context capture bien le refus dans $bot->{replies}
# quel que soit le chemin d'appel (méthode ou fonction de package)
{
    no warnings 'redefine';
    *Mediabot::Context::deny = sub {
        my ($self, $msg) = @_;
        my $bot = $self->{bot} or return;
        my $nick = $self->{nick} // '';
        push @{ $bot->{replies} }, { type => 'notice', to => $nick, text => $msg };
        return;
    };
}

sub refused {
    my ($bot) = @_;
    for my $r ($bot->replies) {
        return 1 if $r->{text} =~ /level|logged|allow|permission/i;
    }
    return 0;
}

return sub {
    my ($assert, $make_bot, $make_msg_chan, $make_msg_priv) = @_;

    # -------------------------------------------------------------------------
    # 1. require_level direct via Context
    # -------------------------------------------------------------------------

    # 1a. Master tente Owner → refus
    {
        my $master = MockUser->new(nick => 'buddy', level => 'Master', auth => 1);
        my $bot    = $make_bot->(user => $master);
        my $msg    = $make_msg_priv->(prefix => 'buddy!buddy@test');
        my $ctx    = Mediabot::Context->new(
            bot => $bot, message => $msg, nick => 'buddy', channel => 'buddy', command => 'test',
        );
        my $ok = $ctx->require_level('Owner');
        $assert->ok(!$ok,          'Master → require_level(Owner) : refusé');
        $assert->ok(refused($bot), 'Master → require_level(Owner) : notice de refus envoyé');
    }

    # 1b. Administrator tente Master → refus
    {
        my $admin = MockUser->new(nick => 'adminX', level => 'Administrator', auth => 1);
        my $bot   = $make_bot->(user => $admin);
        my $msg   = $make_msg_priv->(prefix => 'adminX!a@test');
        my $ctx   = Mediabot::Context->new(
            bot => $bot, message => $msg, nick => 'adminX', channel => 'adminX', command => 'die',
        );
        $assert->ok(!$ctx->require_level('Master'), 'Administrator → require_level(Master) : refusé');
    }

    # 1c. Administrator tente Administrator → ok
    {
        my $admin = MockUser->new(nick => 'adminX', level => 'Administrator', auth => 1);
        my $bot   = $make_bot->(user => $admin);
        my $msg   = $make_msg_priv->(prefix => 'adminX!a@test');
        my $ctx   = Mediabot::Context->new(
            bot => $bot, message => $msg, nick => 'adminX', channel => 'adminX', command => 'kick',
        );
        $assert->ok($ctx->require_level('Administrator'), 'Administrator → require_level(Administrator) : ok');
        $assert->ok($ctx->require_level('User'),          'Administrator → require_level(User) : ok');
    }

    # 1d. User non authentifié → refus même pour level User
    {
        my $anon = MockUser->new(nick => 'lurker', level => 'User', auth => 0);
        my $bot  = $make_bot->(user => $anon);
        my $msg  = $make_msg_priv->(prefix => 'lurker!x@lurk');
        my $ctx  = Mediabot::Context->new(
            bot => $bot, message => $msg, nick => 'lurker', channel => 'lurker', command => 'whoami',
        );
        $assert->ok(!$ctx->require_level('User'), 'Utilisateur non auth → require_level(User) : refusé');
    }

    # -------------------------------------------------------------------------
    # 2. Matrice complète Owner > Master > Admin > User
    # -------------------------------------------------------------------------
    {
        my @levels = ('Owner', 'Master', 'Administrator', 'User');
        my %rank   = (Owner => 0, Master => 1, Administrator => 2, User => 3);

        for my $user_level (@levels) {
            my $user = MockUser->new(nick => 'x', level => $user_level, auth => 1);
            my $bot  = $make_bot->(user => $user);
            my $msg  = $make_msg_priv->(prefix => 'x!x@x');
            my $ctx  = Mediabot::Context->new(
                bot => $bot, message => $msg, nick => 'x', channel => 'x', command => 'test',
            );

            for my $req (@levels) {
                my $should_pass = ($rank{$user_level} <= $rank{$req}) ? 1 : 0;
                $bot->reset_replies;
                my $result = $ctx->require_level($req) ? 1 : 0;
                $assert->is($result, $should_pass,
                    "has_level : $user_level vs require($req) → " . ($should_pass ? 'ok' : 'refusé'));
            }
        }
    }

    # -------------------------------------------------------------------------
    # 3. Commande 'die' avec Master → pas de refus
    # -------------------------------------------------------------------------
    {
        my $master = MockUser->new(nick => 'teuk', level => 'Master', auth => 1);
        my $bot    = $make_bot->(user => $master);
        eval {
            $bot->mbCommandPublic(
                MockMessage->from_channel(prefix => 'teuk!teuk@teuk.org', channel => '#test'),
                '#test', 'teuk', 0, 'die', 'test shutdown'
            );
        };
        $assert->ok(!refused($bot), "Commande 'die' avec Master : pas de refus de niveau");
    }
};