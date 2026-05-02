# t/cases/09_channel_ban_commands.t
# =============================================================================
#  Tests d'intégration des commandes ChannelBan
#  - ban / kickban / kb / unban / bans
#  - vérifie les niveaux channel, les masks dangereux, MODE +b/-b, KICK
#  - sans MariaDB réelle, sans IRC réel
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use MockBot;
use MockIRC;
use MockUser;
use MockMessage;

use Mediabot::Context;
use Mediabot::ChannelCommands;
use Mediabot::ChannelBan;

# -----------------------------------------------------------------------------
# Local mock channel object
# -----------------------------------------------------------------------------
{
    package TestChannel;
    sub new {
        my ($class, %args) = @_;
        return bless {
            id   => $args{id}   // 1,
            name => $args{name} // '#test',
        }, $class;
    }
    sub get_id   { $_[0]->{id} }
    sub get_name { $_[0]->{name} }
}

# -----------------------------------------------------------------------------
# Fake DBH/STH only for the SQL paths used by ChannelCommands.pm:
#   - getIdUserChannelLevel()
#   - _channelban_known_target_level()
#   - _channelban_latest_hostmask_for_nick()
#   - unban SELECT in channelUnban_ctx()
#   - logBot INSERT
# -----------------------------------------------------------------------------
{
    package TestChannelBanDBH;

    sub new {
        my ($class, %args) = @_;
        return bless {
            actor_level   => $args{actor_level} // 75,
            actor_id      => $args{actor_id}    // 1,
            target_levels => $args{target_levels} || {},
            hostmasks     => $args{hostmasks}     || {},
            unban_row     => $args{unban_row},
        }, $class;
    }

    sub prepare {
        my ($self, $sql) = @_;
        return bless {
            dbh  => $self,
            sql  => $sql,
            bind => [],
        }, 'TestChannelBanSTH';
    }

    sub mysql_insertid { 1 }

    package TestChannelBanSTH;

    sub execute {
        my ($self, @bind) = @_;
        $self->{bind} = \@bind;
        return 1;
    }

    sub fetchrow_hashref {
        my ($self) = @_;
        my $sql = $self->{sql};
        my $dbh = $self->{dbh};

        # getIdUserChannelLevel($self, $handle, $channel)
        if ($sql =~ /SELECT\s+USER\.id_user,\s+USER_CHANNEL\.level/is) {
            return {
                id_user => $dbh->{actor_id},
                level   => $dbh->{actor_level},
            };
        }

        # _channelban_known_target_level($channel, $target)
        if ($sql =~ /SELECT\s+u\.id_user,\s+u\.nickname,\s+uc\.level/is) {
            my $target = $self->{bind}[1];
            return unless exists $dbh->{target_levels}{$target};
            return {
                id_user  => 999,
                nickname => $target,
                level    => $dbh->{target_levels}{$target},
            };
        }

        # channelUnban_ctx SELECT
        if ($sql =~ /FROM\s+CHANNEL_BAN/is) {
            return $dbh->{unban_row};
        }

        return undef;
    }

    sub fetchrow_array {
        my ($self) = @_;
        my $sql = $self->{sql};
        my $dbh = $self->{dbh};

        # _channelban_latest_hostmask_for_nick($channel, $nick)
        if ($sql =~ /SELECT\s+cl\.userhost/is) {
            my $nick = $self->{bind}[1];
            return $dbh->{hostmasks}{$nick};
        }

        return;
    }

    sub rows { 1 }
    sub finish { 1 }
}

# -----------------------------------------------------------------------------
# TestChannelBan inherits pure validation/parsing from Mediabot::ChannelBan,
# but stores bans in memory instead of MariaDB.
# -----------------------------------------------------------------------------
{
    package TestChannelBan;
    our @ISA = ('Mediabot::ChannelBan');

    sub new {
        my ($class, %args) = @_;
        return bless {
            next_id => 1,
            bans    => $args{bans} || [],
            added   => [],
            removed => [],
        }, $class;
    }

    sub active_ban_for_mask {
        my ($self, $id_channel, $mask) = @_;
        for my $b (@{ $self->{bans} }) {
            next unless $b->{active};
            next unless $b->{id_channel} == $id_channel;
            next unless $b->{mask} eq $mask;
            return $b;
        }
        return;
    }

    sub add_ban {
        my ($self, %args) = @_;

        if (my $err = $self->validate_mask($args{mask})) {
            return (undef, $err);
        }

        if (my $existing = $self->active_ban_for_mask($args{id_channel}, $args{mask})) {
            return (undef, "an active ban already exists for $args{mask} (id $existing->{id_channel_ban})");
        }

        my $id = $self->{next_id}++;
        my $row = {
            id_channel_ban => $id,
            id_channel     => $args{id_channel},
            mask           => $args{mask},
            ban_level      => $args{ban_level},
            reason         => $args{reason},
            created_by     => $args{created_by},
            created_by_nick => $args{created_by_nick},
            expires_at     => $args{expires_at},
            active         => 1,
            source         => $args{source} || 'irc',
        };

        push @{ $self->{bans} },  $row;
        push @{ $self->{added} }, $row;

        return ($id, undef);
    }

    sub list_active_bans {
        my ($self, $id_channel) = @_;
        return grep { $_->{active} && $_->{id_channel} == $id_channel } @{ $self->{bans} };
    }

    sub mark_removed {
        my ($self, %args) = @_;

        my $selector = $args{selector};
        my $count = 0;

        for my $b (@{ $self->{bans} }) {
            next unless $b->{active};
            next unless $b->{id_channel} == $args{id_channel};

            if (
                (defined $selector && $selector =~ /^\d+$/ && $b->{id_channel_ban} == $selector)
                ||
                (defined $selector && $b->{mask} eq $selector)
            ) {
                $b->{active}          = 0;
                $b->{removed_by}      = $args{removed_by};
                $b->{removed_by_nick} = $args{removed_by_nick};
                $b->{remove_reason}   = $args{remove_reason};
                push @{ $self->{removed} }, $b;
                $count++;
            }
        }

        return ($count, undef);
    }
}

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
sub _make_test_bot {
    my (%args) = @_;

    my $user = $args{user} || MockUser->new(
        id    => 1,
        nick  => 'teuk',
        # Keep this as a non-admin global user.
        # ChannelBan access must be driven by USER_CHANNEL.level in the fake DB.
        level => 'User',
        auth  => 1,
    );

    my $irc = $args{irc} || MockIRC->new(nick => 'mediabotv3');

    my $dbh = $args{dbh} || TestChannelBanDBH->new(
        actor_level => $args{actor_level} // 75,
        hostmasks   => $args{hostmasks}   || {},
    );

    my $channel_ban = $args{channel_ban} || TestChannelBan->new(
        bans => $args{bans} || [],
    );

    my $chan = TestChannel->new(id => 1, name => '#test');

    my $bot = MockBot->new(
        mock_user   => $user,
        irc         => $irc,
        dbh         => $dbh,
        channel_ban => $channel_ban,
        channels    => {
            '#test' => $chan,
            '#Test' => $chan,
            '#TEST' => $chan,
        },
    );

    return ($bot, $irc, $dbh, $channel_ban);
}

sub _ctx {
    my (%args) = @_;

    my $bot     = $args{bot};
    my $nick    = $args{nick}    || 'teuk';
    my $channel = $args{channel} || '#test';
    my $command = $args{command} || 'ban';
    my $argsref = $args{args}    || [];

    my $msg = MockMessage->from_channel(
        prefix  => "$nick!$nick\@example.org",
        channel => $channel,
        text    => '!' . $command . ' ' . join(' ', @$argsref),
    );

    return Mediabot::Context->new(
        bot     => $bot,
        message => $msg,
        nick    => $nick,
        channel => $channel,
        command => $command,
        args    => $argsref,
    );
}

sub _notice_texts {
    my ($irc) = @_;
    return map { $_->{text} // '' } @{ $irc->{sent_notices} || [] };
}

sub _sent_commands {
    my ($irc) = @_;
    return map { $_->{command} // '' } @{ $irc->{sent_messages} || [] };
}

return sub {
    my ($assert) = @_;

    # -------------------------------------------------------------------------
    # 1. level 74 -> ban refused
    # -------------------------------------------------------------------------
    {
        my ($bot, $irc) = _make_test_bot(actor_level => 74);
        my $ctx = _ctx(
            bot     => $bot,
            command => 'ban',
            args    => [ '*!*bad@example.org', '10m', '75', 'too low' ],
        );

        channelBan_ctx($ctx);

        my @cmds = _sent_commands($irc);
        my @notices = _notice_texts($irc);

        $assert->is(scalar @cmds, 0, 'ban level 74 : no IRC MODE sent');
        $assert->ok(join("\n", @notices) =~ /at least 75/i, 'ban level 74 : refusal notice');
    }

    # -------------------------------------------------------------------------
    # 2. level 75 -> explicit mask ban accepted, MODE +b sent
    # -------------------------------------------------------------------------
    {
        my ($bot, $irc, undef, $cb) = _make_test_bot(actor_level => 75);
        my $ctx = _ctx(
            bot     => $bot,
            command => 'ban',
            args    => [ '*!*bad@example.org', '10m', '75', 'test ban' ],
        );

        channelBan_ctx($ctx);

        my @m = @{ $irc->{sent_messages} };
        my @notices = _notice_texts($irc);

        $assert->is(scalar @m, 1, 'ban explicit mask : one IRC message');
        $assert->is($m[0]{command}, 'MODE', 'ban explicit mask : MODE sent');
        $assert->is($m[0]{params}[0], '#test', 'ban explicit mask : channel');
        $assert->is($m[0]{params}[1], '+b', 'ban explicit mask : +b');
        $assert->is($m[0]{params}[2], '*!*bad@example.org', 'ban explicit mask : mask');
        $assert->ok(join("\n", @notices) =~ /Ban #1 added/, 'ban explicit mask : success notice');
        $assert->is(scalar @{ $cb->{added} }, 1, 'ban explicit mask : stored in ChannelBan');
    }

    # -------------------------------------------------------------------------
    # 3. dangerous mask refused before MODE
    # -------------------------------------------------------------------------
    {
        my ($bot, $irc) = _make_test_bot(actor_level => 100);
        my $ctx = _ctx(
            bot     => $bot,
            command => 'ban',
            args    => [ '*!*@*', '10m', '75', 'too broad' ],
        );

        channelBan_ctx($ctx);

        my @cmds = _sent_commands($irc);
        my @notices = _notice_texts($irc);

        $assert->is(scalar @cmds, 0, 'ban broad mask : no IRC MODE sent');
        $assert->ok(join("\n", @notices) =~ /too broad|host part|useful fixed part/i,
            'ban broad mask : refusal notice');
    }

    # -------------------------------------------------------------------------
    # 4. explicit ban level above actor level refused
    # -------------------------------------------------------------------------
    {
        my ($bot, $irc) = _make_test_bot(actor_level => 100);
        my $ctx = _ctx(
            bot     => $bot,
            command => 'ban',
            args    => [ '*!*bad@example.org', '10m', '500', 'too high' ],
        );

        channelBan_ctx($ctx);

        my @cmds = _sent_commands($irc);
        my @notices = _notice_texts($irc);

        $assert->is(scalar @cmds, 0, 'ban level too high : no IRC MODE sent');
        $assert->ok(join("\n", @notices) =~ /higher than your channel level/i,
            'ban level too high : refusal notice');
    }

    # -------------------------------------------------------------------------
    # 5. kickban nick -> resolve hostmask, MODE +b then KICK
    # -------------------------------------------------------------------------
    {
        my $dbh = TestChannelBanDBH->new(
            actor_level => 100,
            hostmasks   => {
                badnick => 'badnick!~evil@evil.example.org',
            },
        );

        my ($bot, $irc, undef, $cb) = _make_test_bot(
            actor_level => 100,
            dbh         => $dbh,
        );

        my $ctx = _ctx(
            bot     => $bot,
            command => 'kickban',
            args    => [ 'badnick', '10m', '75', 'test kickban' ],
        );

        channelKickBan_ctx($ctx);

        my @m = @{ $irc->{sent_messages} };

        $assert->is(scalar @m, 2, 'kickban nick : MODE + KICK sent');
        $assert->is($m[0]{command}, 'MODE', 'kickban nick : first command MODE');
        $assert->is($m[0]{params}[1], '+b', 'kickban nick : +b');
        $assert->is($m[0]{params}[2], '*!*evil@evil.example.org', 'kickban nick : resolved mask');
        $assert->is($m[1]{command}, 'KICK', 'kickban nick : second command KICK');
        $assert->is($m[1]{params}[1], 'badnick', 'kickban nick : kicked nick');
        $assert->is(scalar @{ $cb->{added} }, 1, 'kickban nick : stored in ChannelBan');
    }

    # -------------------------------------------------------------------------
    # 6. bans lists active bans
    # -------------------------------------------------------------------------
    {
        my $ban = {
            id_channel_ban => 42,
            id_channel     => 1,
            mask           => '*!*listed@example.org',
            ban_level      => 75,
            reason         => 'listed test',
            created_by_nick => 'teuk',
            created_at     => '2026-05-02 00:00:00',
            expires_at     => undef,
            active         => 1,
        };

        my ($bot, $irc) = _make_test_bot(
            actor_level => 75,
            bans        => [ $ban ],
        );

        my $ctx = _ctx(
            bot     => $bot,
            command => 'bans',
            args    => [],
        );

        channelBans_ctx($ctx);

        my $txt = join("\n", _notice_texts($irc));
        $assert->ok($txt =~ /#42 \*!\*listed\@example\.org/, 'bans : lists ban id and mask');
        $assert->ok($txt =~ /Showing 1\/1 active bans/, 'bans : summary line');
    }

    # -------------------------------------------------------------------------
    # 7. unban by id -> MODE -b + mark_removed()
    # -------------------------------------------------------------------------
    {
        my $row = {
            id_channel_ban => 51,
            mask           => '*!*remove@example.org',
            ban_level      => 75,
        };

        my $dbh = TestChannelBanDBH->new(
            actor_level => 100,
            unban_row   => $row,
        );

        my $cb = TestChannelBan->new(
            bans => [
                {
                    id_channel_ban => 51,
                    id_channel     => 1,
                    mask           => '*!*remove@example.org',
                    ban_level      => 75,
                    active         => 1,
                }
            ],
        );

        my ($bot, $irc) = _make_test_bot(
            actor_level => 100,
            dbh         => $dbh,
            channel_ban => $cb,
        );

        my $ctx = _ctx(
            bot     => $bot,
            command => 'unban',
            args    => [ '51' ],
        );

        channelUnban_ctx($ctx);

        my @m = @{ $irc->{sent_messages} };
        my $txt = join("\n", _notice_texts($irc));

        $assert->is(scalar @m, 1, 'unban : one IRC message');
        $assert->is($m[0]{command}, 'MODE', 'unban : MODE sent');
        $assert->is($m[0]{params}[1], '-b', 'unban : -b');
        $assert->is($m[0]{params}[2], '*!*remove@example.org', 'unban : mask');
        $assert->ok($txt =~ /Unbanned #51/, 'unban : success notice');
        $assert->is(scalar @{ $cb->{removed} }, 1, 'unban : mark_removed called');
    }
};
