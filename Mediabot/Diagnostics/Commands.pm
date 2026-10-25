package Mediabot::Diagnostics::Commands;

use strict;
use warnings;
use utf8;
use Exporter 'import';
use Mediabot::Helpers ();

our @EXPORT_OK = qw(
    mbFeatures_ctx
    _mbFeatures_chanset_state
    mbObservatory_ctx
    _mbObservatory_uptime
    _mbObservatory_energy_label
);

# Public command views use the historical transport/formatting seam.
# Diagnostic collection, publication and mbweb readers keep their own owners.
sub botPrivmsg { goto &Mediabot::UserCommands::botPrivmsg }
sub botNotice  { goto &Mediabot::UserCommands::botNotice }
sub _fmt_n     { goto &Mediabot::UserCommands::_fmt_n }

# ---------------------------------------------------------------------------
# mbFeatures_ctx --- !features / !capabilities / !caps
# Compact channel capabilities view. No schema change: reads existing chansets,
# runtime objects and known modules.
# ---------------------------------------------------------------------------
sub _mbFeatures_chanset_state {
    my ($self, $channel, $name, %opts) = @_;

    my $default = exists $opts{default} ? $opts{default} : 0;
    my $id = eval { Mediabot::Helpers::getIdChansetList($self, $name) };

    return $default ? 'on (legacy default)' : 'missing'
        unless defined $id && $id ne '';

    my $set = eval { Mediabot::Helpers::getIdChannelSet($self, $channel, $id) };
    return $set ? 'on' : 'off';
}

sub mbFeatures_ctx {
    my ($ctx) = @_;

    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel // '';

    unless ($channel =~ /^#/) {
        botNotice($self, $nick, 'Syntax: features  (must be used in a channel)');
        return 1;
    }

    my $ach_defs = 0;
    eval {
        $ach_defs = scalar keys %{ $self->{achievements}->list_definitions }
            if $self->{achievements};
        1;
    };

    my $ach_announce = _mbFeatures_chanset_state($self, $channel, 'AchievementAnnounce', default => 0);
    my $games        = _mbFeatures_chanset_state($self, $channel, 'Games', default => 1);
    my $urltitle     = _mbFeatures_chanset_state($self, $channel, 'UrlTitle', default => 0);
    my $youtube      = _mbFeatures_chanset_state($self, $channel, 'Youtube', default => 0);
    my $ytsearch     = _mbFeatures_chanset_state($self, $channel, 'YoutubeSearch', default => 0);
    my $randomquote  = _mbFeatures_chanset_state($self, $channel, 'RandomQuote', default => 0);
    my $claude       = _mbFeatures_chanset_state($self, $channel, 'Claude', default => 0);
    my $gemini       = _mbFeatures_chanset_state($self, $channel, 'Gemini', default => 0);
    my $nocolors     = _mbFeatures_chanset_state($self, $channel, 'NoColors', default => 0);
    my $antiflood    = _mbFeatures_chanset_state($self, $channel, 'AntiFlood', default => 0);

    my $metrics = $self->{metrics} ? 'on' : 'off';
    my $radio = 'unknown';
    eval {
        my $enabled = $self->{conf}->get('radio.ENABLED');
        $radio = (defined $enabled && $enabled =~ /^(?:1|yes|true|on)$/i) ? 'on' : 'off';
        1;
    };

    my @lines = (
        "\x{1F52D} Capabilities for $channel",
        "  \x{1F3C6} achievements: " . ($self->{achievements} ? 'on' : 'off')
            . "  | announce: $ach_announce"
            . "  | catalogue: $ach_defs",
        "  \x{1F3B2} games: $games  | commands: duel, horoscope, compat, quotegame",
        "  \x{1F517} links: UrlTitle=$urltitle  Youtube=$youtube  YoutubeSearch=$ytsearch",
        "  \x{1F4AC} social memory: profil/radar/dashboard/leaderboard/awards/yearbook/chronos/mood/memory available",
        "  \x{1F916} integrations: Claude=$claude  Gemini=$gemini  RandomQuote=$randomquote  Radio=$radio",
        "  \x{1F6E1} safety/output: AntiFlood=$antiflood  NoColors=$nocolors  Metrics=$metrics",
        "  Help: help social / help games / help chansets",
    );

    for my $line (@lines) {
        botNotice($self, $nick, $line);
    }

    return 1;
}


# ---------------------------------------------------------------------------
# mbObservatory_ctx --- !observatory / !obs
# A compact public state view for the current channel. No schema change.
# ---------------------------------------------------------------------------
sub _mbObservatory_uptime {
    my $seconds = time() - $^T;
    $seconds = 0 if $seconds < 0;

    my $days = int($seconds / 86400);
    $seconds %= 86400;
    my $hours = int($seconds / 3600);
    $seconds %= 3600;
    my $mins = int($seconds / 60);

    return sprintf('%dd %02dh', $days, $hours) if $days > 0;
    return sprintf('%dh %02dm', $hours, $mins) if $hours > 0;
    return sprintf('%dm', $mins);
}

sub _mbObservatory_energy_label {
    my ($msgs) = @_;
    $msgs ||= 0;

    return 'silent'   if $msgs == 0;
    return 'quiet'    if $msgs < 10;
    return 'awake'    if $msgs < 40;
    return 'lively'   if $msgs < 120;
    return 'storming';
}

sub mbObservatory_ctx {
    my ($ctx) = @_;

    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel // '';

    unless ($channel =~ /^#/) {
        botNotice($self, $nick, 'Syntax: observatory  (must be used in a channel)');
        return 1;
    }

    my $dbh = $self->{dbh};

    my ($msgs_1h, $nicks_1h) = (0, 0);
    eval {
        my $sth = $dbh->prepare(q{
            SELECT COUNT(*) AS msgs, COUNT(DISTINCT cl.nick) AS nicks
            FROM CHANNEL_LOG cl
            JOIN CHANNEL c ON c.id_channel = cl.id_channel
            WHERE c.name = ?
              AND cl.event_type IN ('public','action')
              AND cl.ts >= NOW() - INTERVAL 60 MINUTE
        });
        if ($sth && $sth->execute($channel)) {
            my $r = $sth->fetchrow_hashref || {};
            $msgs_1h = $r->{msgs}  || 0;
            $nicks_1h = $r->{nicks} || 0;
            $sth->finish;
        }
        1;
    };

    my $ach_defs = 0;
    eval {
        $ach_defs = scalar keys %{ $self->{achievements}->list_definitions }
            if $self->{achievements};
        1;
    };

    my $games        = _mbFeatures_chanset_state($self, $channel, 'Games', default => 1);
    my $announce     = _mbFeatures_chanset_state($self, $channel, 'AchievementAnnounce', default => 0);
    my $urltitle     = _mbFeatures_chanset_state($self, $channel, 'UrlTitle', default => 0);
    my $claude       = _mbFeatures_chanset_state($self, $channel, 'Claude', default => 0);
    my $gemini       = _mbFeatures_chanset_state($self, $channel, 'Gemini', default => 0);
    my $antiflood    = _mbFeatures_chanset_state($self, $channel, 'AntiFlood', default => 0);

    my $metrics = $self->{metrics} ? 'on' : 'off';
    my $energy  = _mbObservatory_energy_label($msgs_1h);
    my $uptime  = _mbObservatory_uptime();

    botPrivmsg($self, $channel,
        "\x{1F52D} \x02Observatory\x02 $channel \x{2014} process up $uptime"
      . "  | games $games"
      . "  | achievements " . ($self->{achievements} ? 'on' : 'off')
      . " ($ach_defs)"
      . "  | announce $announce"
    );

    botPrivmsg($self, $channel,
        "\x{1FAC0} last hour: " . _fmt_n($msgs_1h) . " msg(s) / " . _fmt_n($nicks_1h) . " nick(s)"
      . "  | energy $energy"
      . "  | UrlTitle $urltitle"
      . "  | Claude $claude"
      . "  | Gemini $gemini"
      . "  | AntiFlood $antiflood"
      . "  | metrics $metrics"
    );

    $self->{metrics}->inc('mediabot_observatory_total', { channel => $channel }) if $self->{metrics};

    return 1;
}

1;
