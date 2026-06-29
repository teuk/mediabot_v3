# t/cases/586_mb367_partyline_command_error_redaction.t
#
# mb367 — Les commandes Partyline qui capturent localement leurs exceptions
# doivent conserver les détails côté serveur sans les révéler au client.

use strict;
use warnings;

BEGIN {
    for my $module (
        ['IO/Async/Listener.pm',        'IO::Async::Listener'],
        ['IO/Async/Stream.pm',          'IO::Async::Stream'],
        ['IO/Async/Timer/Countdown.pm', 'IO::Async::Timer::Countdown'],
    ) {
        my ($file, $package) = @$module;
        next if $INC{$file};
        eval "package $package; sub new { my (\$class, \%args) = \@_; bless { \%args }, \$class } 1;"
            or die $@;
        $INC{$file} = __FILE__;
    }

    unless ($INC{'JSON.pm'}) {
        eval q{
            package JSON;
            require Exporter;
            our @ISA       = qw(Exporter);
            our @EXPORT_OK = qw(encode_json);
            our @EXPORT    = qw(encode_json);
            sub encode_json {
                require JSON::PP;
                return JSON::PP::encode_json($_[0]);
            }
            1;
        } or die $@;
        $INC{'JSON.pm'} = __FILE__;
    }

    unless ($INC{'Mediabot/External.pm'}) {
        eval q{ package Mediabot::External; 1; } or die $@;
        $INC{'Mediabot/External.pm'} = __FILE__;
    }
}

use FindBin qw($Bin);
use lib "$Bin/../..";
use Mediabot::Partyline;

sub _slurp_586 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path
        or die "cannot read $path: $!";
    local $/;
    my $text = <$fh>;
    close $fh;
    return $text;
}

{
    package MB367::Logger;
    sub new { bless { entries => [] }, shift }
    sub log {
        my ($self, $level, $message) = @_;
        push @{ $self->{entries} }, [$level, $message];
        return 1;
    }
}

{
    package MB367::DyingLogger;
    sub log { die "logger unavailable\n" }
}

{
    package MB367::Stream;
    sub new { bless { writes => [] }, shift }
    sub write {
        my ($self, $text) = @_;
        push @{ $self->{writes} }, $text;
        return 1;
    }
}

{
    package MB367::DyingStream;
    sub write { die "stream unavailable\n" }
}

{
    package MB367::Metrics;
    sub render_prometheus {
        die "metrics backend at /home/mediabot/private.pm line 42\nsecret=token\n";
    }
}

{
    package MB367::Conf;
    sub reload {
        die "config parser at /etc/mediabot/secret.conf line 7\npassword=hunter2\n";
    }
}

{
    package MB367::IRC;
    sub nick_folded { return 'mediabot' }
    sub send_message {
        die "IRC transport at /home/mediabot/socket.pm line 88\nRAW KICK secret\n";
    }
}

{
    package MB367::StatusPartyline;
    our @ISA = qw(Mediabot::Partyline);
    sub _runtime_status_payload {
        die "status SQL SELECT password FROM USER at /srv/bot/status.pm line 9\n";
    }
}

{
    package MB367::DispatchPartyline;
    our @ISA = qw(Mediabot::Partyline);
    sub _handle_line {
        die "dispatch failure at /srv/bot/dispatch.pm line 12\n";
    }
}

return sub {
    my ($assert) = @_;

    my $logger = MB367::Logger->new;
    my $pl = bless { bot => { logger => $logger } }, 'Mediabot::Partyline';

    $assert->ok($pl->can('_report_operation_error'),
        'shared command-error reporter is available');

    my $stream = MB367::Stream->new;
    my $ret = $pl->_report_operation_error(
        $stream,
        "Partyline .test failed\r\nforged-label",
        "Operation failed.\r\nforged-reply",
        "DB error at /home/mediabot/private.pm line 99\r\nSELECT password FROM USER",
    );

    $assert->is($ret, 0,
        'reporter returns a false status to its caller');
    $assert->is(scalar @{ $stream->{writes} }, 1,
        'reporter writes exactly one client response');
    $assert->is($stream->{writes}[0], "Operation failed. forged-reply\r\n",
        'client response is framed once and embedded newlines are neutralized');
    $assert->unlike($stream->{writes}[0], qr{/home/mediabot|SELECT|password|line 99},
        'client response contains no exception internals');

    $assert->is(scalar @{ $logger->{entries} }, 1,
        'reporter keeps one detailed server-log entry');
    $assert->is($logger->{entries}[0][0], 1,
        'reporter uses the existing error log level');
    $assert->is(
        $logger->{entries}[0][1],
        'Partyline .test failed forged-label: DB error at /home/mediabot/private.pm line 99 SELECT password FROM USER',
        'server log keeps details while normalizing labels and multiline errors'
    );
    $assert->unlike($logger->{entries}[0][1], qr/[\r\n]/,
        'server diagnostic remains on one physical log line');

    my $fallback_stream = MB367::Stream->new;
    $pl->_report_operation_error($fallback_stream, '', '', '');
    $assert->is($fallback_stream->{writes}[0], "Internal error.\r\n",
        'blank client message falls back to the sealed generic response');
    $assert->like($logger->{entries}[1][1], qr/^Partyline operation failed: unknown error$/,
        'blank log label and error receive stable defaults');

    my $defensive = bless {
        bot => { logger => bless({}, 'MB367::DyingLogger') },
    }, 'Mediabot::Partyline';
    my $defensive_ok = eval {
        $defensive->_report_operation_error(
            bless({}, 'MB367::DyingStream'),
            'Partyline .test failed',
            'Operation failed.',
            "original failure\n",
        );
        1;
    };
    $assert->ok($defensive_ok,
        'logger and stream failures cannot rethrow during error reporting');

    my $dispatch_logger = MB367::Logger->new;
    my $dispatch_stream = MB367::Stream->new;
    my $dispatch = bless {
        bot => { logger => $dispatch_logger },
    }, 'MB367::DispatchPartyline';
    my $dispatch_ok = $dispatch->_dispatch_line_safely(
        $dispatch_stream, 10, '.help', 'Partyline'
    );
    $assert->is($dispatch_ok, 0,
        'outer safe dispatcher still reports a failed command');
    $assert->is($dispatch_stream->{writes}[0], "Internal error.\r\n",
        'outer dispatcher keeps the MB365 generic client response');
    $assert->like($dispatch_logger->{entries}[0][1], qr/^Partyline exception: dispatch failure/,
        'outer dispatcher keeps the MB365 server-log prefix');

    my $status_logger = MB367::Logger->new;
    my $status_stream = MB367::Stream->new;
    my $status = bless {
        bot => { logger => $status_logger },
    }, 'MB367::StatusPartyline';
    $status->_cmd_status($status_stream, 11);
    $assert->is($status_stream->{writes}[0], "Status unavailable.\r\n",
        '.status exposes only a context-specific generic failure');
    $assert->unlike($status_stream->{writes}[0], qr{SELECT|password|/srv/|line 9},
        '.status response leaks no diagnostic detail');
    $assert->like($status_logger->{entries}[0][1], qr/^Partyline \.status failed: status SQL SELECT password/,
        '.status details remain available in the server log');

    my $metrics_logger = MB367::Logger->new;
    my $metrics_stream = MB367::Stream->new;
    my $metrics_pl = bless {
        bot => {
            logger  => $metrics_logger,
            metrics => bless({}, 'MB367::Metrics'),
        },
    }, 'Mediabot::Partyline';
    $metrics_pl->_cmd_metrics($metrics_stream, 12);
    $assert->is($metrics_stream->{writes}[0], "Metrics render error.\r\n",
        '.metrics exposes only its stable generic failure');
    $assert->unlike($metrics_stream->{writes}[0], qr{secret|token|/home/|line 42},
        '.metrics response leaks no backend exception');
    $assert->like($metrics_logger->{entries}[0][1], qr/^Partyline \.metrics failed: metrics backend/,
        '.metrics backend details remain in the server log');

    my $reload_logger = MB367::Logger->new;
    my $reload_stream = MB367::Stream->new;
    my $reload_pl = bless {
        bot => {
            logger => $reload_logger,
            conf   => bless({}, 'MB367::Conf'),
        },
        users => { 13 => { level => 0, login => 'owner' } },
    }, 'Mediabot::Partyline';
    $reload_pl->_cmd_reload($reload_stream, 13);
    $assert->is($reload_stream->{writes}[0], "Reload failed.\r\n",
        '.reload exposes only its stable generic failure');
    $assert->unlike($reload_stream->{writes}[0], qr{password|hunter2|/etc/|line 7},
        '.reload response leaks no configuration detail');
    $assert->like($reload_logger->{entries}[0][1], qr/^Partyline \.reload failed: config parser/,
        '.reload parser details remain in the server log');

    my $kick_logger = MB367::Logger->new;
    my $kick_stream = MB367::Stream->new;
    my $kick_pl = bless {
        bot => {
            logger => $kick_logger,
            irc    => bless({}, 'MB367::IRC'),
        },
    }, 'Mediabot::Partyline';
    $kick_pl->_cmd_kick($kick_stream, 14, 'badnick #test reason');
    $assert->is($kick_stream->{writes}[0], "Kick failed.\r\n",
        '.kick exposes only its stable generic failure');
    $assert->unlike($kick_stream->{writes}[0], qr{RAW KICK|/home/|line 88},
        '.kick response leaks no IRC transport detail');
    $assert->like($kick_logger->{entries}[0][1], qr/^Partyline \.kick failed: IRC transport/,
        '.kick transport details remain in the server log');

    my $ai_logger = MB367::Logger->new;
    my $ai_stream = MB367::Stream->new;
    my $ai_pl = bless {
        bot => {
            logger   => $ai_logger,
            irc      => bless({}, 'MB367::IRC'),
            channels => {},
        },
        users => { 15 => { login => 'TeuK' } },
    }, 'Mediabot::Partyline';
    {
        no warnings 'redefine';
        local *Mediabot::External::claudeAI = sub {
            die "Claude key at /home/mediabot/secret.conf line 3\nAPI_KEY=forbidden\n";
        };
        $ai_pl->_cmd_ai($ai_stream, 15, 'hello there');
    }
    $assert->is($ai_stream->{writes}[0], "AI request failed.\r\n",
        '.ai exposes only its stable generic failure');
    $assert->unlike($ai_stream->{writes}[0], qr{API_KEY|forbidden|/home/|line 3},
        '.ai response leaks no provider secret or path');
    $assert->like($ai_logger->{entries}[0][1], qr/^Partyline \.ai failed: Claude key/,
        '.ai provider details remain in the server log');

    my $src = _slurp_586("$Bin/../../Mediabot/Partyline.pm");
    $assert->like($src, qr/mb367-B1/,
        'mb367-B1 marker is present');

    my $report_calls = () = $src =~ /->_report_operation_error\(/g;
    $assert->is($report_calls, 8,
        'outer dispatcher and all seven local exception paths use the shared reporter');

    for my $label (
        'Partyline .reloadconf failed',
        'Partyline .status failed',
        'Partyline .metrics failed',
        'Partyline .reload failed',
        'Partyline .ai summary failed',
        'Partyline .ai failed',
        'Partyline .kick failed',
    ) {
        $assert->like($src, qr/\Q$label\E/,
            "$label is routed through the shared redaction helper");
    }

    my @raw_exception_writes = grep {
        /\$stream->write[^;]*\$@/
    } split /\n/, $src;
    $assert->is(scalar @raw_exception_writes, 0,
        'no Partyline stream write interpolates raw $@ anymore');

    $assert->unlike($src, qr/Status unavailable: \$@|Metrics render error: \$@|Reload failed: \$@|Error: \$@/,
        'all known command-local exception disclosure strings are gone');
    $assert->like($src, qr/Configuration reloaded\.\\r\\n/,
        'successful configuration reload output is unchanged');
    $assert->like($src, qr/Kicked \$target from \$chan \(\$reason\)\\r\\n/,
        'successful kick output is unchanged');
};
