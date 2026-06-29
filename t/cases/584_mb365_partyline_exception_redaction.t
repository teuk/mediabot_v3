# t/cases/584_mb365_partyline_exception_redaction.t
#
# mb365 — Les exceptions internes Partyline restent dans les logs serveur et ne
# doivent jamais être renvoyées en clair au client Telnet ou DCC.

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

    # Partyline only calls Mediabot::External methods from unrelated command
    # paths. Keep this unit test independent from the large external stack.
    unless ($INC{'Mediabot/External.pm'}) {
        eval q{ package Mediabot::External; 1; } or die $@;
        $INC{'Mediabot/External.pm'} = __FILE__;
    }
}

use FindBin qw($Bin);
use lib "$Bin/../..";
use Mediabot::Partyline;

sub _slurp_584 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path
        or die "cannot read $path: $!";
    local $/;
    my $text = <$fh>;
    close $fh;
    return $text;
}

{
    package MB365::Logger;
    sub new { bless { entries => [] }, shift }
    sub log {
        my ($self, $level, $message) = @_;
        push @{ $self->{entries} }, [$level, $message];
        return 1;
    }
}

{
    package MB365::DyingLogger;
    sub log { die "logger unavailable\n" }
}

{
    package MB365::Stream;
    sub new { bless { writes => [] }, shift }
    sub write {
        my ($self, $text) = @_;
        push @{ $self->{writes} }, $text;
        return 1;
    }
}

{
    package MB365::DyingStream;
    sub write { die "stream closed\n" }
}

{
    package MB365::Partyline;
    our @ISA = qw(Mediabot::Partyline);

    sub _handle_line {
        my ($self, $stream, $id, $line) = @_;
        push @{ $self->{handled} }, [$id, $line];

        die "DB failure at /home/mediabot/mediabot_v3/Mediabot/Partyline.pm line 999.\nSQL: SELECT password FROM USER\r\n"
            if $self->{must_die};

        return 0; # a false normal return must still count as successful dispatch
    }
}

return sub {
    my ($assert) = @_;

    my $logger = MB365::Logger->new;
    my $pl = bless {
        bot     => { logger => $logger },
        handled => [],
    }, 'MB365::Partyline';

    $assert->ok($pl->can('_dispatch_line_safely'),
        'shared safe-dispatch helper is available');

    my $ok_stream = MB365::Stream->new;
    my $ok = $pl->_dispatch_line_safely($ok_stream, 12, '.help', 'Partyline');
    $assert->is($ok, 1,
        'normal dispatch succeeds even when _handle_line returns a false value');
    $assert->is(scalar @{ $pl->{handled} }, 1,
        'normal command is dispatched exactly once');
    $assert->is($pl->{handled}[0][0], 12,
        'file descriptor is preserved');
    $assert->is($pl->{handled}[0][1], '.help',
        'command line is preserved');
    $assert->is(scalar @{ $ok_stream->{writes} }, 0,
        'successful dispatch writes no internal-error response');
    $assert->is(scalar @{ $logger->{entries} }, 0,
        'successful dispatch logs no exception');

    $pl->{must_die} = 1;
    my $telnet_stream = MB365::Stream->new;
    my $telnet_ok = $pl->_dispatch_line_safely(
        $telnet_stream, 13, '.stat', 'Partyline'
    );

    $assert->is($telnet_ok, 0,
        'Telnet dispatch failure is reported to the caller');
    $assert->is(scalar @{ $telnet_stream->{writes} }, 1,
        'Telnet failure emits exactly one client response');
    $assert->is($telnet_stream->{writes}[0], "Internal error.\r\n",
        'Telnet client receives only the generic error');
    $assert->unlike($telnet_stream->{writes}[0], qr{/home/mediabot|SELECT|password|line 999},
        'Telnet response exposes no exception internals');

    $assert->is(scalar @{ $logger->{entries} }, 1,
        'Telnet failure is retained in the server log');
    $assert->is($logger->{entries}[0][0], 1,
        'exception uses the existing warning/error log level');
    $assert->like($logger->{entries}[0][1], qr/^Partyline exception: DB failure/,
        'server log identifies the Telnet transport and keeps the useful error');
    $assert->like($logger->{entries}[0][1], qr{/home/mediabot/.*SELECT password FROM USER},
        'server log keeps diagnostic details for the administrator');
    $assert->unlike($logger->{entries}[0][1], qr/[\r\n]/,
        'multiline exception is normalized to one log line');

    my $dcc_stream = MB365::Stream->new;
    my $dcc_ok = $pl->_dispatch_line_safely(
        $dcc_stream, 14, '.who', 'DCC CHAT'
    );
    $assert->is($dcc_ok, 0,
        'DCC dispatch failure is reported to the caller');
    $assert->is($dcc_stream->{writes}[0], "Internal error.\r\n",
        'DCC client receives the same generic response');
    $assert->like($logger->{entries}[1][1], qr/^DCC CHAT exception:/,
        'DCC failure keeps its transport name in the server log');

    my $silent = bless {
        bot      => { logger => bless({}, 'MB365::DyingLogger') },
        handled  => [],
        must_die => 1,
    }, 'MB365::Partyline';
    my $closed = bless {}, 'MB365::DyingStream';
    my $defensive_ok = eval {
        $silent->_dispatch_line_safely($closed, 15, '.help', 'Partyline');
        1;
    };
    $assert->ok($defensive_ok,
        'logger or stream failures do not rethrow the original Partyline exception');

    my $src = _slurp_584("$Bin/../../Mediabot/Partyline.pm");
    $assert->like($src, qr/mb365-B1/,
        'mb365-B1 marker is present');
    $assert->like(
        $src,
        qr/_dispatch_line_safely\(\$stream, \$id, \$line, 'DCC CHAT'\)/,
        'DCC input path uses the shared safe dispatcher'
    );
    $assert->like(
        $src,
        qr/_dispatch_line_safely\(\$stream, \$id, \$line, 'Partyline'\)/,
        'Telnet input path uses the shared safe dispatcher'
    );
    $assert->unlike($src, qr/Internal error: \$@/,
        'raw exception is no longer interpolated into a client response');
    $assert->unlike($src, qr/\$stream->write\("Internal error: /,
        'no detailed internal-error response remains');
};
