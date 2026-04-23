package Mediabot::Metrics;

use strict;
use warnings;

use IO::Socket::INET;
use IO::Async::Listener;
use JSON::MaybeXS qw(encode_json);

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
    $self->_declare('mediabot_channel_commands_total', 'counter', 'Total public commands executed in a channel');
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

    $self->_declare('mediabot_partyline_sessions_current', 'gauge',   'Current open Partyline sessions');
    $self->_declare('mediabot_partyline_logins_total',     'counter', 'Total successful Partyline logins');

    $self->_declare('mediabot_db_connected',           'gauge',   'Whether the database is currently reachable');
    $self->_declare('mediabot_db_query_errors_total',  'counter', 'Total database query errors');
    $self->_declare('mediabot_timers_current',         'gauge',   'Current number of active timers');
    $self->_declare('mediabot_channels_managed',       'gauge',   'Current number of managed channels');
    $self->_declare('mediabot_users_known',            'gauge',   'Current number of known users');

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

    # dynamic values refreshed at render time
    $self->set('mediabot_uptime_seconds', time() - $self->{started});

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

    return join("\n", @out) . "\n";
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

            my $buffer = '';

            $stream->configure(
                on_read => sub {
                    my ($stream, $buffref, $eof) = @_;

                    $buffer .= $$buffref;
                    $$buffref = '';

                    if ($buffer =~ /\r?\n\r?\n/s || $eof) {
                        my ($method, $path) = $buffer =~ m{^([A-Z]+)\s+(\S+)\s+HTTP/}m;

                        my ($status, $body, $ctype);

                        if (($method || '') eq 'GET' && ($path || '') eq '/metrics') {
                            $status = '200 OK';
                            $body   = $self->render_prometheus();
                            $ctype  = 'text/plain; version=0.0.4; charset=utf-8';
                        }
                        elsif (($method || '') eq 'GET' && ($path || '') eq '/api/radio/status') {
                            $status = '200 OK';
                            $body   = $self->render_radio_status_json();
                            $ctype  = 'application/json; charset=utf-8';
                        }
                        else {
                            $status = '404 Not Found';
                            $body   = "Not Found\n";
                            $ctype  = 'text/plain; charset=utf-8';
                        }

                        my $resp = join(
                            "\r\n",
                            "HTTP/1.1 $status",
                            "Content-Type: $ctype",
                            "Content-Length: " . length($body),
                            "Connection: close",
                            "",
                            $body
                        );

                        $stream->write($resp);
                        $stream->close_when_empty;
                    }

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

    # Normalize level: accept numeric (0,1,2…) or symbolic ('INFO','ERROR',…)
    my %_sym = ( INFO => 0, DEBUG => 2, WARN => 1, WARNING => 1, ERROR => 1 );
    my $numeric_level = (defined $level && $level =~ /^[0-9]+$/)
        ? $level
        : ($_sym{ uc($level // '') } // 1);

    if ($self->{logger}->can('log')) {
        eval { $self->{logger}->log($numeric_level, $msg); };
        return;
    }

    # Fallback for loggers that only expose named methods
    if ($numeric_level == 0 && $self->{logger}->can('info')) {
        eval { $self->{logger}->info($msg); };
        return;
    }

    if ($numeric_level >= 1 && $self->{logger}->can('error')) {
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