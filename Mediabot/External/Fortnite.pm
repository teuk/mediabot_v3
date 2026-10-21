package Mediabot::External::Fortnite;

use strict;
use warnings;
use utf8;
use Exporter 'import';
use JSON::MaybeXS;
use String::IRC;

our @EXPORT_OK = qw(getFortniteId fortniteStats_ctx);

# Return the Fortnite account id stored for a Mediabot user nickname.
# This is used by fortniteStats_ctx() before calling fortnite-api.com.

sub getFortniteId {
    my ($self, $sUser) = @_;

    return undef unless defined($sUser) && $sUser ne '';
    return undef unless $self->{dbh};

    my $sQuery = "SELECT fortniteid FROM USER WHERE nickname = ?";
    my $sth = $self->{dbh}->prepare($sQuery);

    unless ($sth) {
        $self->{logger}->log(1, "getFortniteId() SQL prepare error : " . $DBI::errstr . " Query : " . $sQuery)
            if $self->{logger};
        return undef;
    }

    unless ($sth->execute($sUser)) {
        $self->{logger}->log(1, "getFortniteId() SQL execute error : " . $DBI::errstr . " Query : " . $sQuery)
            if $self->{logger};
        $sth->finish;
        return undef;
    }

    my $fortniteid;
    if (my $ref = $sth->fetchrow_hashref()) {
        $fortniteid = $ref->{fortniteid};
    }

    $sth->finish;
    return $fortniteid;
}


# Fortnite stats:
#   f <username>
#
# Requires:
#   - Logged in
#   - Level >= User

sub fortniteStats_ctx {
    my ($ctx) = @_;

    my $self    = $ctx->bot;
    my $nick    = $ctx->nick;
    my $channel = $ctx->channel;
    my $message = $ctx->message;

    # Reply target (notice in private, privmsg in channel)
    my $is_private = (!defined($channel) || $channel eq '');
    my $reply_to   = $is_private ? $nick : $channel;

    # Normalize args (only accept ARRAY)
    my @args = (ref($ctx->args) eq 'ARRAY') ? @{ $ctx->args } : ();
    unless (@args && defined $args[0] && $args[0] ne '') {
        Mediabot::Helpers::botNotice($self, $nick, "Syntax: f <username>");
        return;
    }

    # API key from config
    my $api_key = eval { $self->{conf}->get('fortnite.API_KEY') } // '';
    unless ($api_key) {
        $self->{logger}->log(1, "fortniteStats_ctx(): fortnite.API_KEY is undefined in config file");
        return;
    }

    # Auth + level checks (Context)
    my $user = $ctx->user || $self->Mediabot::External::get_user_from_message($message);
    unless ($user && $user->is_authenticated) {
        my $who = $user ? ($user->nickname // 'unknown') : 'unknown';
        my $msg = $message->prefix . " f command attempt (user $who is not logged in)";
        Mediabot::Helpers::noticeConsoleChan($self, $msg);
        Mediabot::Helpers::botNotice($self, $nick,
            "You must be logged to use this command - /msg "
          . $self->{irc}->nick_folded
          . " login username password"
        );
        Mediabot::Helpers::logBot($self, $message, undef, "f", $msg);
        return;
    }

    unless (eval { $user->has_level("User") }) {
        my $lvl = eval { $user->level_description } || eval { $user->level } || '?';
        my $msg = $message->prefix . " f command attempt (requires User for "
                . ($user->nickname // $nick) . " [$lvl])";
        Mediabot::Helpers::noticeConsoleChan($self, $msg);
        Mediabot::Helpers::botNotice($self, $nick, "This command is not available for your level. Contact a bot master.");
        Mediabot::Helpers::logBot($self, $message, undef, "f", $msg);
        return;
    }

    my $target_name = $args[0];

    # Resolve internal user + fortniteid (keep legacy helpers)
    my $id_user = Mediabot::External::getIdUser($self, $target_name);
    unless (defined $id_user) {
        Mediabot::Helpers::botNotice($self, $nick, "Undefined user $target_name");
        return;
    }

    my $account_id = getFortniteId($self, $target_name);
    unless (defined $account_id && $account_id ne '') {
        Mediabot::Helpers::botNotice($self, $nick, "Undefined fortniteid for user $target_name");
        return;
    }

    # Call API
    my $url = "https://fortnite-api.com/v2/stats/br/v2/$account_id";

    my $http = Mediabot::External::_make_http(timeout => 10, verify_SSL => 1);
    my $http_response = eval { $http->get(
        $url,
        { headers => { 'Authorization' => $api_key } }
    ) } // { success => 0, status => 0, reason => $@ };

    unless ($http_response->{success}) {
        $self->{logger}->log(3, "fortniteStats_ctx(): HTTP error $http_response->{status} $http_response->{reason}");
        Mediabot::Helpers::botPrivmsg($self, $reply_to, "Fortnite stats: service unavailable, try again later.");
        return;
    }

    my $json_details = $http_response->{content};
    unless (defined $json_details && $json_details ne '') {
        $self->{logger}->log(3, "fortniteStats_ctx(): empty API response for $target_name/$account_id");
        Mediabot::Helpers::botPrivmsg($self, $reply_to, "Fortnite stats: service unavailable, try again later.");
        return;
    }

    my $data = eval { decode_json($json_details) };
    if ($@ || ref($data) ne 'HASH') {
        $self->{logger}->log(3, "fortniteStats_ctx(): JSON decode/structure error: $@");
        Mediabot::Helpers::botPrivmsg($self, $reply_to, "Fortnite stats: unexpected API response.");
        return;
    }

    # mb875: a declared API status is a three-digit scalar, never a JSON
    # container/boolean or a number inferred from the prefix of arbitrary text.
    if (exists $data->{status}
        && (!defined $data->{status} || ref($data->{status})
            || $data->{status} !~ /\A[0-9]{3}\z/)) {
        $self->{logger}->log(3, 'fortniteStats_ctx(): invalid API status');
        Mediabot::Helpers::botPrivmsg($self, $reply_to, 'Fortnite stats: unexpected API response.');
        return;
    }

    # API may return {status:..., error:...}
    if (exists $data->{status} && $data->{status} != 200) {
        my $err = defined $data->{error} && !ref($data->{error})
            ? $data->{error} : "API error";
        $self->{logger}->log(3, "fortniteStats_ctx(): API status=$data->{status} error=$err");
        Mediabot::Helpers::botPrivmsg($self, $reply_to, "Fortnite stats: $err");
        return;
    }

    my $payload = $data->{data};
    unless ($payload && ref($payload) eq 'HASH') {
        Mediabot::Helpers::botPrivmsg($self, $reply_to, "Fortnite stats: no data for this account.");
        return;
    }

    my $account    = ref($payload->{account})    eq 'HASH' ? $payload->{account}    : {};
    my $battlepass = ref($payload->{battlePass}) eq 'HASH' ? $payload->{battlePass} : {};
    my $stats      = ref($payload->{stats})      eq 'HASH' ? $payload->{stats}      : {};
    my $all_stats  = ref($stats->{all})          eq 'HASH' ? $stats->{all}          : {};

    # Some payloads are nested differently depending on API versions / modes.
    # Keep this defensive: API responses can be valid JSON but missing parts.
    #
    # Preferred:
    #   stats.all.overall
    #
    # Fallback:
    #   stats.all.solo / duo / trio / squad
    my $overall = {};

    if (ref($all_stats->{overall}) eq 'HASH') {
        $overall = $all_stats->{overall};
    }
    else {
        for my $mode (qw(solo duo trio squad)) {
            next unless ref($all_stats->{$mode}) eq 'HASH';

            $overall = $all_stats->{$mode};
            last;
        }
    }

    # Nested objects are guarded above; their display leaves must also be
    # scalars. Keep all existing scalar values and missing-field defaults.
    my $scalar_or = sub {
        my ($value, $fallback) = @_;
        return defined $value && !ref($value) ? $value : $fallback;
    };
    my $name        = $scalar_or->($account->{name}, $target_name);
    my $matches     = $scalar_or->($overall->{matches}, 0);
    my $wins        = $scalar_or->($overall->{wins}, 0);
    my $win_rate    = $scalar_or->($overall->{winRate}, 0);
    my $kills       = $scalar_or->($overall->{kills}, 0);
    my $kd          = $scalar_or->($overall->{kd}, 0);
    my $top3        = $scalar_or->($overall->{top3}, 0);
    my $top5        = $scalar_or->($overall->{top5}, 0);
    my $top10       = $scalar_or->($overall->{top10}, 0);
    my $bp_level    = $scalar_or->($battlepass->{level}, 0);
    my $bp_progress = $scalar_or->($battlepass->{progress}, 0);

    # mb421-R1: l'API renvoie winRate/kd en flottants non bornés
    # (ex. kd=1.2345678901). Les afficher bruts est illisible sur IRC. On
    # arrondit pour l'affichage : K/D à 2 décimales, taux de victoire à 1.
    # Les valeurs non numériques (API inattendue) retombent sur la brute.
    my $fmt_num = sub {
        my ($v, $dp) = @_;
        return $v unless defined $v && $v =~ /\A-?\d+(?:\.\d+)?\z/;
        my $s = sprintf("%.${dp}f", $v);
        $s =~ s/\.?0+\z// if index($s, '.') >= 0;   # 1.50 -> 1.5, 2.00 -> 2
        return $s;
    };
    $kd       = $fmt_num->($kd, 2);
    $win_rate = $fmt_num->($win_rate, 1);

    # Readable on dark/light: bold labels only (no background colors)
    my $user_tag = String::IRC->new('[' . $name . ']')->bold;

    my $line =
        "Fortnite -- $user_tag "
      . (String::IRC->new('Matches:')->bold . " $matches")
      . " | " . (String::IRC->new('Wins:')->bold . " $wins ($win_rate%)")
      . " | " . (String::IRC->new('Kills:')->bold . " $kills")
      . " | " . (String::IRC->new('K/D:')->bold . " $kd")
      . " | " . (String::IRC->new('BP:')->bold . " L$bp_level ($bp_progress%)")
      . " | " . (String::IRC->new('Top3/5/10:')->bold . " $top3/$top5/$top10");

    Mediabot::Helpers::botPrivmsg($self, $reply_to, $line);

    Mediabot::Helpers::logBot($self, $message, $channel, "f", @args);
    return 1;
}

1;
