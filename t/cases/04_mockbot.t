# t/cases/04_mockbot.t
# =============================================================================
#  Tests d'intégrité du framework de test lui-même
#  - MockBot capture bien botPrivmsg / botNotice
#  - reset_replies() vide bien le tableau
#  - MockUser has_level() est cohérent avec Mediabot::User
#  - MockMessage génère les bons attributs
#  - MockIRC capture send_message / do_NOTICE
# =============================================================================

use strict;
use warnings;
BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

return sub {
    my ($assert, $make_bot, $make_msg_chan, $make_msg_priv) = @_;

    # -------------------------------------------------------------------------
    # 1. MockBot - capture botPrivmsg
    # -------------------------------------------------------------------------
    {
        my $bot = $make_bot->();
        $bot->botPrivmsg('#test', 'hello channel');
        $bot->botPrivmsg('teuk',  'hello nick');

        my @r = $bot->replies;
        $assert->is(scalar @r, 2, 'MockBot : 2 réponses capturées');
        $assert->is($r[0]->{type}, 'privmsg',        'MockBot : type = privmsg');
        $assert->is($r[0]->{to},   '#test',           'MockBot : to = #test');
        $assert->is($r[0]->{text}, 'hello channel',   'MockBot : text correct');
        $assert->is($r[1]->{to},   'teuk',            'MockBot : to nick');
    }

    # -------------------------------------------------------------------------
    # 2. MockBot - capture botNotice
    # -------------------------------------------------------------------------
    {
        my $bot = $make_bot->();
        $bot->botNotice('teuk', 'You are not logged in.');

        my @n = $bot->notices;
        $assert->is(scalar @n, 1,                      'MockBot : 1 notice capturé');
        $assert->is($n[0]->{type}, 'notice',           'MockBot : type = notice');
        $assert->is($n[0]->{text}, 'You are not logged in.', 'MockBot : texte notice correct');
    }

    # -------------------------------------------------------------------------
    # 3. MockBot - botNotice avec target/text vides → silencieux
    # -------------------------------------------------------------------------
    {
        my $bot = $make_bot->();
        $bot->botNotice('',    'some text');
        $bot->botNotice('teuk', '');
        $bot->botNotice(undef, 'text');
        my @r = $bot->replies;
        $assert->is(scalar @r, 0, 'MockBot : botNotice invalide ignoré silencieusement');
    }

    # -------------------------------------------------------------------------
    # 4. MockBot - reset_replies()
    # -------------------------------------------------------------------------
    {
        my $bot = $make_bot->();
        $bot->botPrivmsg('#test', 'msg1');
        $bot->botPrivmsg('#test', 'msg2');
        $assert->is(scalar($bot->replies), 2, 'MockBot : 2 avant reset');
        $bot->reset_replies;
        $assert->is(scalar($bot->replies), 0, 'MockBot : 0 après reset');
    }

    # -------------------------------------------------------------------------
    # 5. MockBot - replied_with()
    # -------------------------------------------------------------------------
    {
        my $bot = $make_bot->();
        $bot->botPrivmsg('#test', 'Mediabot version: 3.0dev');
        $assert->ok($bot->replied_with('version'),      'replied_with(version) : match');
        $assert->ok($bot->replied_with('3\\.0'),        'replied_with(3.0) : match regex');
        $assert->ok(!$bot->replied_with('nyan cat'),    'replied_with(nyan cat) : pas de match');
    }

    # -------------------------------------------------------------------------
    # 6. MockUser - has_level() hiérarchie
    # -------------------------------------------------------------------------
    {
        my $owner = MockUser->new(nick => 'o', level => 'Owner', auth => 1);
        $assert->ok($owner->has_level('Owner'),         'MockUser Owner → Owner : ok');
        $assert->ok($owner->has_level('Master'),        'MockUser Owner → Master : ok');
        $assert->ok($owner->has_level('User'),          'MockUser Owner → User : ok');

        my $user = MockUser->new(nick => 'u', level => 'User', auth => 1);
        $assert->ok(!$user->has_level('Master'),        'MockUser User → Master : refusé');
        $assert->ok(!$user->has_level('Owner'),         'MockUser User → Owner : refusé');
        $assert->ok($user->has_level('User'),           'MockUser User → User : ok');

        my $anon = MockUser->new(nick => 'a', level => 'User', auth => 0);
        $assert->ok(!$anon->is_authenticated,           'MockUser non auth : is_authenticated = false');
    }

    # -------------------------------------------------------------------------
    # 7. MockMessage::from_channel
    # -------------------------------------------------------------------------
    {
        my $msg = MockMessage->from_channel(
            prefix  => 'nick!user@host',
            channel => '#chan',
            text    => '!echo test',
        );
        $assert->is($msg->prefix,       'nick!user@host', 'MockMessage::from_channel prefix');
        $assert->is($msg->{params}[0],  '#chan',           'MockMessage::from_channel params[0]');
        $assert->is($msg->text,         '!echo test',      'MockMessage::from_channel text');
        $assert->ok($msg->can('prefix'),                   'MockMessage::can(prefix)');
    }

    # -------------------------------------------------------------------------
    # 8. MockMessage::from_private
    # -------------------------------------------------------------------------
    {
        my $msg = MockMessage->from_private(
            prefix => 'teuk!teuk@teuk.org',
            text   => 'status',
        );
        $assert->is($msg->prefix,      'teuk!teuk@teuk.org', 'MockMessage::from_private prefix');
        $assert->is($msg->{params}[0], 'teuk',               'MockMessage::from_private params[0] = nick');
    }

    # -------------------------------------------------------------------------
    # 9. MockIRC - capture send_message / do_NOTICE / reset_capture
    # -------------------------------------------------------------------------
    {
        require MockIRC;
        my $irc = MockIRC->new(nick => 'testbot');
        $assert->is($irc->nick_folded, 'testbot', 'MockIRC nick_folded');

        $irc->send_message('QUIT', undef, 'bye');
        $irc->do_NOTICE(target => 'teuk', text => 'hello');

        $assert->is(scalar @{$irc->{sent_messages}}, 1, 'MockIRC : send_message capturé');
        $assert->is($irc->{sent_messages}[0]{command}, 'QUIT', 'MockIRC : commande QUIT');
        $assert->is(scalar @{$irc->{sent_notices}},  1, 'MockIRC : do_NOTICE capturé');
        $assert->is($irc->{sent_notices}[0]{target}, 'teuk',  'MockIRC : target notice');

        $irc->reset_capture;
        $assert->is(scalar @{$irc->{sent_messages}}, 0, 'MockIRC reset : sent_messages vide');
        $assert->is(scalar @{$irc->{sent_notices}},  0, 'MockIRC reset : sent_notices vide');
    }
};
