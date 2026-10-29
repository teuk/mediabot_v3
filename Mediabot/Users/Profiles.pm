package Mediabot::Users::Profiles;

use strict;
use warnings;
use utf8;
use Exporter 'import';

our @EXPORT_OK = qw(
    userStats_ctx
    userInfo_ctx
    userGreet_ctx
);

# Resolve the historical facade's transport/logging/text hooks at call time.
sub botNotice     { goto &Mediabot::UserCommands::botNotice }
sub botPrivmsg    { goto &Mediabot::UserCommands::botPrivmsg }
sub logBot        { goto &Mediabot::UserCommands::logBot }
sub truncate_utf8 { goto &Mediabot::UserCommands::truncate_utf8 }

# Account statistics and profile/greet views retain their original Context gates.
sub userStats_ctx {
    my ($ctx) = @_;

    return unless $ctx->require_level('Master');

    my $bot  = $ctx->bot;
    my $nick = $ctx->nick;

    my $sql_total = "SELECT COUNT(*) AS nbUsers FROM USER";
    my ($sth, $total);
    my $total_ok = eval {
        $sth = $bot->{dbh}->prepare($sql_total);
        die "prepare failed\n" unless $sth;
        die "execute failed\n" unless $sth->execute();
        ($total) = $sth->fetchrow_array;
        die "fetch failed\n" if $sth->err || !defined($total);
        1;
    };
    eval { $sth->finish } if $sth;
    unless ($total_ok) {
        eval { $bot->{logger}->log(1, "userStats_ctx() total read failed.") }
            if $bot->{logger};
        $bot->botNotice($nick, "Internal error while reading user statistics.");
        return;
    }

    my $sql_levels = q{
        SELECT description, COUNT(*)
        FROM USER
        JOIN USER_LEVEL USING(id_user_level)
        GROUP BY description
        ORDER BY level
    };

    my ($level_sth, @level_parts);
    my $levels_ok = eval {
        $level_sth = $bot->{dbh}->prepare($sql_levels);
        die "prepare failed\n" unless $level_sth;
        die "execute failed\n" unless $level_sth->execute();
        # II10: collect levels and display as one-liner after confirming EOF.
        while (my ($desc, $count) = $level_sth->fetchrow_array) {
            $desc  //= 'Unknown';
            $count //= 0;
            push @level_parts, "$desc:$count";
        }
        die "fetch failed\n" if $level_sth->err;
        1;
    };
    eval { $level_sth->finish } if $level_sth;
    unless ($levels_ok) {
        eval { $bot->{logger}->log(1, "userStats_ctx() levels read failed.") }
            if $bot->{logger};
        $bot->botNotice($nick, "Internal error while reading user level statistics.");
        return;
    }
    if (@level_parts) {
        $bot->botNotice($nick, "Users: $total total — " . join(', ', @level_parts));
    } else {
        $bot->botNotice($nick, "Users: $total total");
    }

}

sub userInfo_ctx {
    my ($ctx) = @_;
    return unless $ctx;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;

    # Global Administrator+ is allowed to inspect user information.
    # The internal help table already documents userinfo as admin-level.
    $ctx->require_level('Administrator') or return;

    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();
    my $target = $args[0] // '';

    if ($target eq '') {
        botNotice($self, $nick, "Syntax: userinfo <username>");
        return;
    }

    my $sQuery = q{
        SELECT
            USER.id_user,
            USER.nickname,
            USER.creation_date,
            USER.last_login,
            CASE
                WHEN USER.password IS NOT NULL AND USER.password <> '' THEN 1
                ELSE 0
            END AS has_password,
            USER.info1,
            USER.info2,
            USER.auth,
            USER.username,
            USER_LEVEL.level,
            USER_LEVEL.description
        FROM USER
        JOIN USER_LEVEL ON USER_LEVEL.id_user_level = USER.id_user_level
        WHERE USER.nickname = ?
        LIMIT 1
    };

    my $sth = $self->{dbh}->prepare($sQuery);
    unless ($sth && $sth->execute($target)) {
        $self->{logger}->log(1, "userInfo_ctx() SQL Error: $DBI::errstr | Query: $sQuery");
        $sth->finish if $sth;
        return;
    }

    if (my $ref = $sth->fetchrow_hashref()) {
        my $id_user     = $ref->{id_user}       // '?';
        my $nickname    = $ref->{nickname}      // '?';
        my $created     = $ref->{creation_date} // 'N/A';
        my $last_login  = $ref->{last_login}    // 'never';

        my @hostmasks;
        my $hm_sth = $self->{dbh}->prepare(
            "SELECT hostmask FROM USER_HOSTMASK WHERE id_user=? ORDER BY id_user_hostmask LIMIT 20"
        );

        if ($hm_sth && $hm_sth->execute($id_user)) {
            while (my $hm_ref = $hm_sth->fetchrow_hashref) {
                push @hostmasks, $hm_ref->{hostmask}
                    if defined($hm_ref->{hostmask}) && $hm_ref->{hostmask} ne '';
            }
            $hm_sth->finish;
        }
        else {
            $self->{logger}->log(1, "userInfo_ctx() hostmask SQL Error: $DBI::errstr")
                if $self->{logger};
            $hm_sth->finish if $hm_sth;
        }

        my $has_password = defined($ref->{has_password}) ? int($ref->{has_password}) : 0;
        my $level        = defined $ref->{level}       ? $ref->{level}       : '?';
        my $level_d  = defined $ref->{description} ? $ref->{description} : '?';
        my $auth     = defined $ref->{auth}        ? $ref->{auth}        : 0;
        my $username = defined $ref->{username}    ? $ref->{username}    : '';
        my $info1    = defined $ref->{info1}       ? $ref->{info1}       : '';
        my $info2    = defined $ref->{info2}       ? $ref->{info2}       : '';

        # Compact output — 2 NOTICE lines to avoid Excess Flood
        my $pass_set = $has_password ? 'yes' : 'no';
        botNotice($self, $nick,
            "[$id_user] $nickname | Level: $level_d | Auth: $auth | Pass: $pass_set"
            . ($username ne '' ? " | Username: $username" : "")
        );
        botNotice($self, $nick,
            "Created: $created | Last login: $last_login"
            . ($info1 ne '' ? " | Info1: $info1" : "")
            . ($info2 ne '' ? " | Info2: $info2" : "")
        );

        if (@hostmasks) {
            my $mask_count = scalar(@hostmasks);
            botNotice($self, $nick, "Hostmasks: $mask_count shown, max 20");

            my $per_line = 2;
            my $page     = 1;

            while (@hostmasks) {
                my @chunk = splice(@hostmasks, 0, $per_line);
                my $line  = sprintf("userinfo-masks[%02d]: %s", $page, join(' | ', @chunk));

                if (length($line) > 360) {
                    $line = truncate_utf8($line, 357);
                }

                botNotice($self, $nick, $line);
                $page++;
            }
        }
        else {
            botNotice($self, $nick, "Hostmasks: none");
        }
    }
    else {
        botNotice($self, $nick, "Unknown user $target");
    }

    $sth->finish;
    return;
}

sub userGreet_ctx {
    my ($ctx) = @_;

    my $self = $ctx->bot;
    my $nick = $ctx->nick;

    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();

    my $is_private = !defined($ctx->channel) || $ctx->channel eq '';
    my $dest_chan  = $ctx->channel;  # where to speak if public

    # Resolve target channel:
    # - if first arg is #channel, use it
    # - else use ctx->channel (only if it's a channel)
    my $target_chan = '';
    if (@args && defined $args[0] && $args[0] =~ /^#/) {
        $target_chan = shift @args;
    } else {
        my $cc = $ctx->channel // '';
        $target_chan = ($cc =~ /^#/) ? $cc : '';
    }

    if ($is_private && $target_chan eq '') {
        botNotice($self, $nick, "Syntax (in private): greet #channel <nick>");
        return;
    }

    unless ($target_chan =~ /^#/) {
        botNotice($self, $nick, "Syntax: greet [#channel] <nick>");
        return;
    }

    # Who are we querying the greet for?
    my $greet_nick = (defined $args[0] && $args[0] ne '') ? $args[0] : $nick;
    $greet_nick =~ s/^\s+|\s+$//g;
    $greet_nick =~ s/!.*$//; # if someone passes nick!ident@host, keep nick

    my $say = sub {
        my ($text) = @_;
        if ($is_private) {
            botNotice($self, $nick, $text);
        } else {
            botPrivmsg($self, $dest_chan, $text);
        }
    };

    my $sql = <<'SQL';
SELECT uc.greet AS greet
FROM CHANNEL c
JOIN USER_CHANNEL uc ON uc.id_channel = c.id_channel
JOIN USER u         ON u.id_user     = uc.id_user
WHERE c.name = ?
  AND u.nickname = ?
LIMIT 1
SQL

    my ($sth, $ref);
    my $read_ok = eval {
        $sth = $self->{dbh}->prepare($sql);
        die "prepare failed\n" unless $sth;
        die "execute failed\n" unless $sth->execute($target_chan, $greet_nick);
        $ref = $sth->fetchrow_hashref();
        die "fetch failed\n" if $sth->err;
        1;
    };
    # Decide whether the read succeeded before cleanup can clear DBI errors.
    eval { $sth->finish } if $sth;
    unless ($read_ok) {
        eval { $self->{logger}->log(1, "userGreet_ctx() database read failed.") }
            if $self->{logger};
        $say->("Database error while fetching greet for $greet_nick on $target_chan.");
        return;
    }

    my $greet = ($ref && defined $ref->{greet} && $ref->{greet} ne '') ? $ref->{greet} : undef;

    if (defined $greet) {
        $say->("greet on $target_chan ($greet_nick) $greet");
    } else {
        $say->("No greet for $greet_nick on $target_chan");
    }

    my $pfx = ($ctx->message && $ctx->message->can('prefix')) ? ($ctx->message->prefix // $nick) : $nick;
    logBot($self, $ctx->message, ($is_private ? undef : $dest_chan), "greet", "$pfx greet on $greet_nick for $target_chan");

    return 1;
}

1;
