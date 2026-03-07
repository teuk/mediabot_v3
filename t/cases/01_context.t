# t/cases/01_context.t
# =============================================================================
#  Tests unitaires de Mediabot::Context et Mediabot::Command
#  - construction, getters, arg(), args_as_string()
#  - require_level() avec MockUser de différents niveaux
#  - reply helpers (botNotice capturé par MockBot)
# =============================================================================

use strict;
use warnings;
BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}
use Mediabot::Context;
use Mediabot::Command;

return sub {
    my ($assert, $make_bot, $make_msg_chan, $make_msg_priv) = @_;

    # -------------------------------------------------------------------------
    # 1. Context - construction et getters basiques
    # -------------------------------------------------------------------------
    {
        my $bot = $make_bot->();
        my $msg = $make_msg_chan->(channel => '#blabla', prefix => 'teuk!teuk@teuk.org');
        my $ctx = Mediabot::Context->new(
            bot     => $bot,
            message => $msg,
            nick    => 'teuk',
            channel => '#blabla',
            command => 'echo',
            args    => ['hello', 'world'],
        );

        $assert->is($ctx->nick,    'teuk',    'Context->nick()');
        $assert->is($ctx->channel, '#blabla', 'Context->channel()');
        $assert->is($ctx->command, 'echo',    'Context->command()');

        my $args = $ctx->args;
        $assert->ok(ref($args) eq 'ARRAY', 'Context->args() retourne un arrayref');
        $assert->is($args->[0], 'hello', 'Context->args()->[0]');
        $assert->is($args->[1], 'world', 'Context->args()->[1]');
    }

    # -------------------------------------------------------------------------
    # 2. Context->args() edge cases
    # -------------------------------------------------------------------------
    {
        my $bot = $make_bot->();
        my $msg = $make_msg_chan->();

        # Pas d'args fournis
        my $ctx_noargs = Mediabot::Context->new(
            bot => $bot, message => $msg, nick => 'x', channel => '#x', command => 'test',
        );
        my $a = $ctx_noargs->args;
        $assert->ok(ref($a) eq 'ARRAY', 'Context->args() sans args = arrayref');
        $assert->is(scalar @$a, 0, 'Context->args() sans args = tableau vide');

        # Args comme scalaire (cas dégénéré)
        my $ctx_scalar = Mediabot::Context->new(
            bot => $bot, message => $msg, nick => 'x', channel => '#x', command => 'test',
            args => 'single',
        );
        my $b = $ctx_scalar->args;
        $assert->ok(ref($b) eq 'ARRAY', 'Context->args() scalaire wrappé en arrayref');
        $assert->is($b->[0], 'single', 'Context->args() scalaire : valeur correcte');
    }

    # -------------------------------------------------------------------------
    # 3. Command - construction et helpers arg() / args_as_string()
    # -------------------------------------------------------------------------
    {
        my $bot = $make_bot->();
        my $msg = $make_msg_chan->();
        my $ctx = Mediabot::Context->new(
            bot => $bot, message => $msg, nick => 'teuk', channel => '#test', command => 'say',
            args => ['foo', 'bar', 'baz'],
        );

        my $cmd = Mediabot::Command->new(
            name    => 'say',
            args    => ['foo', 'bar', 'baz'],
            raw     => '!say foo bar baz',
            context => $ctx,
            source  => 'public',
        );

        $assert->is($cmd->name,   'say',   'Command->name()');
        $assert->is($cmd->source, 'public','Command->source()');
        $assert->is($cmd->raw,    '!say foo bar baz', 'Command->raw()');

        $assert->is($cmd->arg(0),  'foo',     'Command->arg(0)');
        $assert->is($cmd->arg(1),  'bar',     'Command->arg(1)');
        $assert->is($cmd->arg(2),  'baz',     'Command->arg(2)');
        $assert->is($cmd->arg(99, 'default'), 'default', 'Command->arg() valeur par défaut');

        $assert->is($cmd->args_as_string(),  'foo bar baz', 'Command->args_as_string()');
        $assert->is($cmd->args_as_string(1), 'bar baz',     'Command->args_as_string(1)');
        $assert->is($cmd->args_as_string(2), 'baz',         'Command->args_as_string(2)');
        $assert->is($cmd->args_as_string(3), '',            'Command->args_as_string() hors limites = ""');
    }

    # -------------------------------------------------------------------------
    # 4. Command - shortcuts vers Context (nick, channel, is_private)
    # -------------------------------------------------------------------------
    {
        my $bot = $make_bot->();
        my $msg = $make_msg_chan->(channel => '#media');
        my $ctx = Mediabot::Context->new(
            bot => $bot, message => $msg, nick => 'gwen', channel => '#media', command => 'op',
        );
        my $cmd = Mediabot::Command->new(name => 'op', context => $ctx);

        $assert->is($cmd->nick,    'gwen',   'Command->nick() via Context');
        $assert->is($cmd->channel, '#media', 'Command->channel() via Context');
    }

    # -------------------------------------------------------------------------
    # 5. require_level() - Owner passe tout
    # -------------------------------------------------------------------------
    {
        my $owner = MockUser->new(nick => 'teuk', level => 'Owner', auth => 1);
        my $bot   = $make_bot->(user => $owner);
        my $msg   = $make_msg_priv->(prefix => 'teuk!teuk@teuk.org');
        my $ctx   = Mediabot::Context->new(
            bot => $bot, message => $msg, nick => 'teuk', channel => 'teuk', command => 'die',
        );

        $assert->ok($ctx->require_level('Owner'),         'require_level(Owner) avec Owner');
        $assert->ok($ctx->require_level('Master'),        'require_level(Master) avec Owner');
        $assert->ok($ctx->require_level('Administrator'), 'require_level(Administrator) avec Owner');
        $assert->ok($ctx->require_level('User'),          'require_level(User) avec Owner');
    }

    # -------------------------------------------------------------------------
    # 6. require_level() - User ne peut pas appeler commandes Master
    # -------------------------------------------------------------------------
    {
        my $user = MockUser->new(nick => 'rando', level => 'User', auth => 1);
        my $bot  = $make_bot->(user => $user);
        my $msg  = $make_msg_priv->(prefix => 'rando!rando@somewhere');
        my $ctx  = Mediabot::Context->new(
            bot => $bot, message => $msg, nick => 'rando', channel => 'rando', command => 'die',
        );

        $assert->ok(!$ctx->require_level('Master'),  'require_level(Master) avec User → refus');
        $assert->ok(!$ctx->require_level('Owner'),   'require_level(Owner) avec User → refus');
        $assert->ok($ctx->require_level('User'),     'require_level(User) avec User → ok');

        # Le refus doit générer un notice
        my @notices = $bot->notices;
        $assert->ok(scalar @notices > 0, 'require_level refusé → notice envoyé');
        $assert->like($notices[0]->{text}, qr/level|command|allow/i, 'notice de refus contient un message intelligible');
    }

    # -------------------------------------------------------------------------
    # 7. require_level() - non authentifié → refus
    # -------------------------------------------------------------------------
    {
        my $anon = MockUser->new(nick => 'lurker', level => 'User', auth => 0);
        my $bot  = $make_bot->(user => $anon);
        my $msg  = $make_msg_priv->(prefix => 'lurker!lurker@lurk.net');
        my $ctx  = Mediabot::Context->new(
            bot => $bot, message => $msg, nick => 'lurker', channel => 'lurker', command => 'status',
        );

        $assert->ok(!$ctx->require_level('User'), 'require_level avec user non auth → refus');
    }
};
