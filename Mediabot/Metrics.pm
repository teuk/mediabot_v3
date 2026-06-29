package Mediabot::Metrics;

use strict;
use warnings;

use IO::Socket::INET;
use IO::Async::Listener;
use JSON::MaybeXS qw(encode_json);
use Encode qw(encode_utf8);   # mb129-B3: Content-Length doit etre en bytes

use constant MAX_HTTP_HEADER_BYTES => 16 * 1024;

sub new {
    my ($class, %args) = @_;

    my $self = bless {
        enabled   => $args{enabled} ? 1 : 0,
        bind      => $args{bind}    || '127.0.0.1',
        port      => $args{port}    || 9108,
        loop      => $args{loop},
        logger    => $args{logger},
        started   => time(),
        listener  => undef,
        metrics   => {},
        radio_status_provider => undef,
    }, $class;

    # Core metrics
    $self->_declare('mediabot_up',                     'gauge',   'Whether the bot process is up');
    $self->_declare('mediabot_start_time_seconds',     'gauge',   'Unix start time of the bot process');
    $self->_declare('mediabot_uptime_seconds',         'gauge',   'Uptime of the bot process in seconds');
    $self->_declare('mediabot_build_info',             'gauge',   'Build and runtime identity info');

    $self->_declare('mediabot_irc_connected',          'gauge',   'Whether the bot is currently connected to IRC');
    $self->_declare('mediabot_irc_reconnect_total',    'counter', 'Total IRC reconnect attempts');
    $self->_declare('mediabot_irc_login_total',        'counter', 'Total successful IRC login events');
    $self->_declare('mediabot_current_channels',       'gauge',   'Current number of joined channels');

    $self->_declare('mediabot_channel_joined',         'gauge',   'Whether the bot is currently joined to a channel');
    $self->_declare('mediabot_channel_nick_count',     'gauge',   'Current nick count seen in a channel');
    $self->_declare('mediabot_channel_autojoin',       'gauge',   'Whether a channel is configured as auto_join');
    $self->_declare('mediabot_channel_lines_in_total', 'counter', 'Total incoming public channel lines');
    $self->_declare('mediabot_channel_bans_active',        'gauge',   'Current active bans per channel', ['channel']);
    $self->_declare('mediabot_channel_bans_added_total',   'counter', 'Total bans added per channel',   ['channel']);
    $self->_declare('mediabot_channel_bans_expired_total', 'counter', 'Total bans expired',             []);
    $self->_declare('mediabot_channel_commands_total', 'counter', 'Total public commands executed in a channel');
    $self->_declare('mediabot_commands_by_name_total', 'counter', 'Total commands dispatched per command name', ['command']);
    $self->_declare('mediabot_channel_commands_by_name_total', 'counter', 'Total public commands executed in a channel by command');

    $self->_declare('mediabot_commands_public_total',  'counter', 'Total public IRC commands executed');
    $self->_declare('mediabot_commands_private_total', 'counter', 'Total private IRC commands executed');
    $self->_declare('mediabot_commands_partyline_total','counter','Total Partyline commands executed');
    $self->_declare('mediabot_command_errors_total',   'counter', 'Total command execution errors');

    $self->_declare('mediabot_privmsg_in_total',       'counter', 'Total incoming PRIVMSG lines');
    $self->_declare('mediabot_privmsg_out_total',      'counter', 'Total outgoing PRIVMSG lines');
    $self->_declare('mediabot_notice_out_total',       'counter', 'Total outgoing NOTICE lines');

    $self->_declare('mediabot_rehash_total',           'counter', 'Total rehash operations');
    $self->_declare('mediabot_restart_total',          'counter', 'Total restart operations');
    $self->_declare('mediabot_jump_total',             'counter', 'Total jump operations');

    $self->_declare('mediabot_auth_success_total',     'counter', 'Total successful bot auth events');
    $self->_declare('mediabot_auth_failure_total',     'counter', 'Total failed bot auth events');
    $self->_declare('mediabot_auth_sessions_total',    'gauge',   'Current in-memory authenticated sessions');  # A8

    $self->_declare('mediabot_partyline_sessions_current', 'gauge',   'Current open Partyline sessions');
    $self->_declare('mediabot_partyline_logins_total',     'counter', 'Total successful Partyline logins');

    $self->_declare('mediabot_db_connected',           'gauge',   'Whether the database is currently reachable');
    $self->_declare('mediabot_db_query_errors_total',  'counter', 'Total database query errors');
    $self->_declare('mediabot_timers_current',         'gauge',   'Current number of active timers');
    $self->_declare('mediabot_channels_managed',       'gauge',   'Current number of managed channels');
    # AF: antiflood metrics
    $self->_declare('mediabot_antiflood_blocks_total',  'counter', 'Bot output silenced by checkAntiFlood (AF1)');
    $self->_declare('mediabot_nickflood_blocks_total',  'counter', 'Commands dropped by per-nick flood guard (AF3)');
    $self->_declare('mediabot_chanflood_blocks_total',  'counter', 'Commands dropped by per-channel flood guard (AF4)');
    # NS: netsplit metrics
    $self->_declare('mediabot_netsplit_quits_total',    'counter', 'QUIT messages identified as netsplit (NS1)');
    $self->_declare('mediabot_netsplit_rejoins_total',  'counter', 'Netsplit NETJOIN events detected (NS4)');
    # FF10: uptime gauge
    $self->_declare('mediabot_uptime_seconds',          'gauge',   'Bot uptime in seconds (FF10)');
    $self->_declare('mediabot_nickflood_mutes_total',   'counter', 'Nick auto-mutes triggered by 3-strike rule (CC3/AF7)');
    $self->_declare('mediabot_cmdcooldown_blocks_total','counter', 'Commands blocked by per-cmd cooldown (CC1)');
    $self->_declare('mediabot_karma_brigade_blocks',    'counter', 'Karma votes blocked by anti-brigade (DD9)');
    $self->_declare('mediabot_users_known',            'gauge',   'Current number of known users');

    # AA6: game and interaction metrics
    $self->_declare('mediabot_trivia_rounds_total',    'counter', 'Total trivia rounds completed (correct answers)');
    $self->_declare('mediabot_trivia_timeouts_total',  'counter', 'Total trivia rounds ended by timeout');
    $self->_declare('mediabot_trivia_db_saves_total',  'counter', 'Total trivia scores persisted to DB (AA1)');
    $self->_declare('mediabot_poll_created_total',     'counter', 'Total polls started');
    $self->_declare('mediabot_poll_closed_total',      'counter', 'Total polls closed via !pollresult');
    $self->_declare('mediabot_poll_votes_total',       'counter', 'Total votes cast across all polls');
    $self->_declare('mediabot_poll_duration_seconds',  'gauge',   'Duration in seconds of the last closed poll');
    $self->_declare('mediabot_karma_votes_total',      'counter', 'Total karma votes cast (++ and --)');
    $self->_declare('mediabot_karmahist_requests_total','counter', 'Total !karmahist requests');
    $self->_declare('mediabot_karma_selfvote_blocked', 'counter', 'Total self-vote attempts blocked (Y2)');
    $self->_declare('mediabot_karma_cooldown_blocked', 'counter', 'Total karma votes blocked by cooldown (U6)');
    $self->_declare('mediabot_hailo_learn_reply_total','counter', 'Total Hailo learn_reply calls');
    $self->_declare('mediabot_hailo_timeout_total',    'counter', 'Total Hailo learn_reply timeouts (AA5)');

    # mb102-mb109: métriques ajoutées lors des passes d'amélioration
    $self->_declare('mediabot_urltitle_requests_total', 'counter',
        'Total URL title lookups by type (mb102-IMP3)', ['type']);
    $self->_declare('mediabot_ytsearch_requests_total', 'counter',
        'Total YouTube search requests (L3)');
    $self->_declare('mediabot_claude_requests_total',   'counter',
        'Total Claude API requests');
    $self->_declare('mediabot_claude_errors_total',     'counter',
        'Total Claude API errors');
    $self->_declare('mediabot_claude_ratelimit_total',  'counter',
        'Total Claude API rate-limit hits');
    $self->_declare('mediabot_nick_changes_total',      'counter',
        'Total NICK changes seen (mb108-IMP3)');
    $self->_declare('mediabot_joins_total',             'counter',
        'Total JOIN events by channel (mb109-IMP2)', ['channel']);
    $self->_declare('mediabot_parts_total',             'counter',
        'Total PART events by channel (mb109-IMP2)', ['channel']);
    $self->_declare('mediabot_trivia_correct_total',    'counter',
        'Total correct trivia answers');
    $self->_declare('mediabot_trivia_timeout_total',    'counter',
        'Total trivia timeouts');
    $self->_declare('mediabot_trivia_questions_total',  'counter',
        'Total trivia questions asked (mb111-IMP3)');

    # mb115: système d'achievements
    $self->_declare('mediabot_achievements_unlocked_total', 'counter',
        'Total achievements unlocked by id (mb115)', ['achievement']);

    # mb116: nouvelles commandes ludiques
    $self->_declare('mediabot_duel_total', 'counter',
        'Total duels played by channel (mb116)', ['channel']);
    $self->_declare('mediabot_horoscope_total', 'counter',
        'Total horoscope consultations (mb116)');

    # mb117: compat, quotegame, mood
    $self->_declare('mediabot_compat_total', 'counter',
        'Total compatibility checks (mb117)', ['channel']);
    $self->_declare('mediabot_quotegame_correct_total', 'counter',
        'Total quotegame correct answers (mb117)');
    $self->_declare('mediabot_mood_total', 'counter',
        'Total mood readings by channel (mb117)', ['channel']);

    # mb118: chronos / leaderboard tracked indirectly via other counters
    $self->_declare('mediabot_chronos_total', 'counter',
        'Total chronos timeline displays (mb118)', ['channel']);
    $self->_declare('mediabot_observatory_total', 'counter',
        'Total observatory status displays (mb126)', ['channel']);
    $self->_declare('mediabot_wordcount_requests_total','counter',
        'Total !wordcount requests (mb115 polish)');

    # Defaults
    if ($self->enabled) {
        $self->set('mediabot_up', 1);
        $self->set('mediabot_start_time_seconds', $self->{started});
        $self->set('mediabot_irc_connected', 0);
        $self->set('mediabot_current_channels', 0);
        $self->set('mediabot_db_connected', 0);
        $self->set('mediabot_partyline_sessions_current', 0);
    }

    return $self;
}

sub enabled {
    my ($self) = @_;
    return $self->{enabled} ? 1 : 0;
}

sub set_build_info {
    my ($self, %args) = @_;
    return unless $self->enabled;

    my %labels = (
        version => defined $args{version} ? $args{version} : 'unknown',
        network => defined $args{network} ? $args{network} : 'unknown',
        nick    => defined $args{nick}    ? $args{nick}    : 'unknown',
    );

    $self->set('mediabot_build_info', 1, \%labels);
}

sub declare {
    my ($self, $name, $type, $help) = @_;
    return $self->_declare($name, $type, $help);
}

sub inc {
    my ($self, $name, $labels) = @_;
    return unless $self->enabled;
    return $self->add($name, 1, $labels);
}

sub add {
    my ($self, $name, $value, $labels) = @_;
    return unless $self->enabled;

    $value = 0 unless defined $value;
    my $entry = $self->{metrics}{$name} or return;
    my $key   = $self->_labels_key($labels);

    $entry->{values}{$key} //= 0;
    $entry->{values}{$key} += $value;
    return 1;
}

sub set {
    my ($self, $name, $value, $labels) = @_;
    return unless $self->enabled;

    $value = 0 unless defined $value;
    my $entry = $self->{metrics}{$name} or return;
    my $key   = $self->_labels_key($labels);

    $entry->{values}{$key} = $value;
    return 1;
}

sub get {
    my ($self, $name, $labels) = @_;
    return undef unless $self->enabled;

    my $entry = $self->{metrics}{$name} or return undef;
    my $key   = $self->_labels_key($labels);

    return $entry->{values}{$key};
}

sub render_prometheus {
    my ($self) = @_;

    return "# Mediabot metrics disabled\n" unless $self->enabled;

    # Cache the rendered output for 5 seconds to avoid redundant work on
    # fast Prometheus scrape intervals or concurrent HTTP clients.
    my $now = time();
    if ($self->{_render_cache}
        && ($now - ($self->{_render_cache_at} // 0)) < 5)
    {
        return $self->{_render_cache};
    }

    # dynamic values refreshed at render time
    $self->set('mediabot_uptime_seconds', $now - $self->{started});

    my @out;

    for my $name (sort keys %{ $self->{metrics} }) {
        my $m = $self->{metrics}{$name};
        next unless $m;

        push @out, sprintf("# HELP %s %s", $name, $m->{help});
        push @out, sprintf("# TYPE %s %s", $name, $m->{type});

        my $values = $m->{values} || {};
        for my $label_key (sort keys %$values) {
            my $v = $values->{$label_key};
            $v = 0 unless defined $v;

            if (defined $label_key && length $label_key) {
                push @out, sprintf('%s{%s} %s', $name, $label_key, $v);
            } else {
                push @out, sprintf('%s %s', $name, $v);
            }
        }

        push @out, '';
    }

    my $rendered = join("\n", @out) . "\n";
    $self->{_render_cache}    = $rendered;
    $self->{_render_cache_at} = time();
    return $rendered;
}

# mb364-B1: keep the tiny embedded HTTP server bounded. Prometheus and the
# radio-status endpoint only need a small request header; accepting an
# unterminated header forever lets a slow/malicious client grow the process
# buffer without limit.
sub _http_request_state {
    my ($self, $buffer, $eof) = @_;

    $buffer = '' unless defined $buffer;

    return 'too_large' if length($buffer) > MAX_HTTP_HEADER_BYTES;
    return 'complete'  if $buffer =~ /\r?\n\r?\n/s || $eof;
    return 'incomplete';
}

sub _http_response_bytes {
    my ($self, $status, $body, $ctype) = @_;

    $status ||= '500 Internal Server Error';
    $body   = '' unless defined $body;
    $ctype  ||= 'text/plain; charset=utf-8';

    # mb129-B3: Content-Length must describe bytes, not Perl characters.
    my $body_bytes = encode_utf8($body);

    return join(
        "\r\n",
        "HTTP/1.1 $status",
        "Content-Type: $ctype",
        "Content-Length: " . length($body_bytes),
        "Connection: close",
        "",
        $body_bytes
    );
}

sub _route_http_request {
    my ($self, $buffer) = @_;

    my ($method, $path) = ($buffer // '') =~ m{^([A-Z]+)\s+(\S+)\s+HTTP/}m;

    if (($method || '') eq 'GET' && ($path || '') eq '/metrics') {
        return $self->_http_response_bytes(
            '200 OK',
            $self->render_prometheus(),
            'text/plain; version=0.0.4; charset=utf-8',
        );
    }

    if (($method || '') eq 'GET' && ($path || '') eq '/api/radio/status') {
        return $self->_http_response_bytes(
            '200 OK',
            $self->render_radio_status_json(),
            'application/json; charset=utf-8',
        );
    }

    return $self->_http_response_bytes(
        '404 Not Found',
        "Not Found\n",
        'text/plain; charset=utf-8',
    );
}

sub start_http_server {
    my ($self) = @_;
    return unless $self->enabled;
    return unless $self->{loop};
    return 1 if $self->{listener};

    my $sock = IO::Socket::INET->new(
        LocalAddr => $self->{bind},
        LocalPort => $self->{port},
        Proto     => 'tcp',
        Listen    => 5,
        ReuseAddr => 1,
    );

    unless ($sock) {
        $self->_log("ERROR", "Metrics: failed to bind $self->{bind}:$self->{port}: $!");
        return;
    }

    my $listener = IO::Async::Listener->new(
        handle => $sock,

        on_stream => sub {
            my ($listener, $stream) = @_;

            my $buffer    = '';
            my $responded = 0;

            $stream->configure(
                on_read => sub {
                    my ($stream, $buffref, $eof) = @_;

                    return 0 if $responded;

                    $buffer .= $$buffref;
                    $$buffref = '';

                    my $state = $self->_http_request_state($buffer, $eof);
                    return 0 if $state eq 'incomplete';

                    $responded = 1;

                    my $resp = $state eq 'too_large'
                        ? $self->_http_response_bytes(
                            '431 Request Header Fields Too Large',
                            "Request Header Fields Too Large\n",
                            'text/plain; charset=utf-8',
                        )
                        : $self->_route_http_request($buffer);

                    $stream->write($resp);
                    $stream->close_when_empty;

                    # Release the request bytes immediately; a slow client must
                    # not keep the already-answered header alive until teardown.
                    $buffer = '';

                    return 0;
                },
            );

            $self->{loop}->add($stream);
        },
    );

    $self->{loop}->add($listener);

    $self->{listener} = $listener;
    $self->_log("INFO", "Metrics endpoint listening on $self->{bind}:$self->{port}");

    return 1;
}

sub stop_http_server {
    my ($self) = @_;
    return 1 unless $self->{listener};

    eval { $self->{loop}->remove($self->{listener}); };
    $self->{listener} = undef;
    return 1;
}

sub _declare {
    my ($self, $name, $type, $help) = @_;

    $type ||= 'gauge';
    $help ||= $name;

    $self->{metrics}{$name} ||= {
        type   => $type,
        help   => $help,
        values => {},
    };

    return 1;
}

sub _labels_key {
    my ($self, $labels) = @_;
    return '' unless $labels && ref $labels eq 'HASH' && %$labels;

    my @pairs;
    for my $k (sort keys %$labels) {
        my $v = defined $labels->{$k} ? $labels->{$k} : '';
        $v =~ s/\\/\\\\/g;
        $v =~ s/"/\\"/g;
        $v =~ s/\n/\\n/g;
        push @pairs, sprintf('%s="%s"', $k, $v);
    }

    return join(',', @pairs);
}

sub _log {
    my ($self, $level, $msg) = @_;
    return unless $self->{logger};

    # MB305: Mediabot::Log uses level 0 for messages that must remain visible
    # even when MAIN_PROG_DEBUG=0. Metrics errors used to map to level 1 and
    # could therefore hide a bind failure or a radio-status provider failure.
    # Keep numeric levels unchanged and normalize symbolic levels explicitly.
    my $symbolic = (defined($level) && $level !~ /^[0-9]+$/)
        ? uc($level)
        : undef;

    my %symbolic_level = (
        INFO    => 0,
        ERROR   => 0,
        WARN    => 1,
        WARNING => 1,
        DEBUG   => 2,
    );

    my $numeric_level = (defined($level) && $level =~ /^[0-9]+$/)
        ? int($level)
        : ($symbolic_level{$symbolic // ''} // 1);

    if ($self->{logger}->can('log')) {
        eval { $self->{logger}->log($numeric_level, $msg); };
        return;
    }

    # Fallback for loggers exposing named methods only. Preserve the semantic
    # meaning of the symbolic level instead of inferring it from debug depth.
    if (defined($symbolic) && $symbolic =~ /^(?:ERROR|WARN|WARNING)$/) {
        if ($self->{logger}->can('error')) {
            eval { $self->{logger}->error($msg); };
            return;
        }
    }

    if (defined($symbolic) && $symbolic eq 'DEBUG') {
        if ($self->{logger}->can('debug')) {
            eval { $self->{logger}->debug($msg); };
            return;
        }
    }

    if ($self->{logger}->can('info')) {
        eval { $self->{logger}->info($msg); };
        return;
    }

    if ($self->{logger}->can('error')) {
        eval { $self->{logger}->error($msg); };
        return;
    }
}

sub set_radio_status_provider {
    my ($self, $cb) = @_;
    $self->{radio_status_provider} = $cb if ref($cb) eq 'CODE';
    return 1;
}

sub render_radio_status_json {
    my ($self) = @_;

    my $provider = $self->{radio_status_provider};
    unless ($provider && ref($provider) eq 'CODE') {
        return encode_json({
            ok    => 0,
            error => 'radio status provider not configured',
        });
    }

    my $payload = eval { $provider->() };
    if ($@) {
        my $err = $@ || 'unknown provider error';
        $self->_log("ERROR", "Radio status provider failed: $err");
        return encode_json({
            ok    => 0,
            error => "radio status provider failed: $err",
        });
    }

    if (!$payload || ref($payload) ne 'HASH') {
        return encode_json({
            ok    => 0,
            error => 'radio status provider returned invalid payload',
        });
    }

    return encode_json($payload);
}

1;
