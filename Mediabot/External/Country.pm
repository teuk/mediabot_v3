package Mediabot::External::Country;

use strict;
use warnings;
use utf8;
use Exporter 'import';
use Socket ();
use JSON::MaybeXS ();
use HTTP::Tiny;
use POSIX qw(WNOHANG);
use Encode ();
use IO::Async::Stream;
use IO::Async::Timer::Countdown;

our @EXPORT_OK = qw(whereis whereis_async);

# Country lookup owns its transport and existing asynchronous lifecycle.
# Helpers remains the compatibility API. Resolve its optional hooks at call
# time; loading this module alone must not pull in bot or database state.
sub _compat_whereis {
    return Mediabot::Helpers::whereis(@_) if defined &Mediabot::Helpers::whereis;
    return whereis(@_);
}

sub inet_aton {
    return Mediabot::Helpers::inet_aton(@_) if defined &Mediabot::Helpers::inet_aton;
    return Socket::inet_aton(@_);
}

sub inet_ntoa {
    return Mediabot::Helpers::inet_ntoa(@_) if defined &Mediabot::Helpers::inet_ntoa;
    return Socket::inet_ntoa(@_);
}

sub decode_json ($) {
    return &Mediabot::Helpers::decode_json if defined &Mediabot::Helpers::decode_json;
    return &JSON::MaybeXS::decode_json;
}

sub whereis {
    my ($self, $sHostname) = @_;

    $self->{logger}->log(4, "whereis() " . (defined($sHostname) && !ref($sHostname) ? $sHostname : ''))
        if $self->{logger};

    # MB314: whereis() is consumed directly by the WHOIS callback, so it must
    # always return a defined printable value. Reject references and blank input
    # before they can stringify into ARRAY(...)/HASH(...) hostnames.
    return 'N/A' unless defined($sHostname) && !ref($sHostname);

    $sHostname =~ s/^\s+|\s+$//g;
    return 'N/A' if $sHostname eq '';

    if ($sHostname =~ /(?:^|\.)users\.undernet\.org\z/i) {
        return 'on an Undernet hidden host ;)';
    }

    my $userIP;

    if ($sHostname =~ /\A\d{1,3}(?:\.\d{1,3}){3}\z/) {
        # inet_aton validates each octet and canonicalizes the IPv4 address.
        my $packed_ip = inet_aton($sHostname);
        return 'N/A' unless defined $packed_ip;
        $userIP = inet_ntoa($packed_ip);
    }
    else {
        my $packed_ip = gethostbyname($sHostname);
        return 'N/A' unless defined $packed_ip;
        $userIP = inet_ntoa($packed_ip);
    }

    return 'N/A'
        unless defined($userIP)
            && $userIP =~ /\A\d{1,3}(?:\.\d{1,3}){3}\z/;

    my $whereis_url = "https://api.country.is/$userIP";
    my $response = eval { HTTP::Tiny->new(timeout => 3, verify_SSL => 1)->get($whereis_url); }
                // { success => 0, status => 0, reason => $@ };

    return "N/A" unless ref($response) eq 'HASH';
    return "N/A" unless $response->{success};

    my $line = $response->{content} // '';
    return 'N/A' unless $line ne '';

    my $json = eval { decode_json $line };
    return 'N/A'
        if $@ || !defined($json) || ref($json) ne 'HASH';

    my $country = $json->{country};
    return 'N/A' unless defined($country) && !ref($country);

    $country =~ s/^\s+|\s+$//g;
    return $country ne '' ? $country : 'N/A';
}


# MB316: run the potentially blocking hostname lookup and country.is request in
# a child process. The parent consumes the tiny result pipe through IO::Async so
# a slow resolver or remote API cannot freeze IRC processing.
sub whereis_async {
    my ($self, $sHostname, $callback, %opts) = @_;

    return 0 unless ref($callback) eq 'CODE';

    my $timeout = $opts{timeout};
    $timeout = 5
        unless defined($timeout)
            && !ref($timeout)
            && $timeout =~ /\A\d+(?:\.\d+)?\z/;
    $timeout = 0.1 if $timeout < 0.1;
    $timeout = 15  if $timeout > 15;

    my $loop = eval { $self->getLoop };
    $loop ||= $self->{loop} if ref($self) eq 'HASH' || ref($self);

    # Lightweight tests and emergency callers may not have an IO::Async loop.
    # Keep compatibility without introducing a sleep or an unbounded wait.
    unless ($loop && $loop->can('add') && $loop->can('remove')) {
        my $country = _compat_whereis($self, $sHostname);
        $country = 'N/A'
            unless defined($country) && !ref($country) && $country ne '';
        eval { $callback->($country); 1; };
        return 1;
    }

    my $child_pid = open(my $pipe, '-|');

    unless (defined $child_pid) {
        eval { $callback->('N/A'); 1; };
        return 1;
    }

    if ($child_pid == 0) {
        # Do not run inherited bot/DB/IRC destructors in the forked child.
        # The synchronous helper needs no bot state beyond an optional logger.
        my $country = eval { _compat_whereis({}, $sHostname) };
        $country = 'N/A'
            unless defined($country) && !ref($country) && $country ne '';
        $country = substr($country, 0, 128);

        my $payload = Encode::encode('UTF-8', $country);
        my $offset  = 0;
        local $SIG{PIPE} = 'IGNORE';
        binmode(STDOUT, ':raw');

        while ($offset < length($payload)) {
            my $written = syswrite(
                STDOUT,
                $payload,
                length($payload) - $offset,
                $offset,
            );

            next if !defined($written) && $!{EINTR};
            last unless defined($written) && $written > 0;
            $offset += $written;
        }

        POSIX::_exit(0);
    }

    my $state = {
        output      => '',
        pipe_eof    => 0,
        child_done  => 0,
        finalized   => 0,
        timed_out   => 0,
        wait_failed => 0,
        wait_status => undef,
        term_sent   => 0,
        kill_sent   => 0,
    };

    my ($stream, $timeout_timer, $kill_timer, $reap_timer);
    my ($finish, $schedule_reap);

    my $remove_timer = sub {
        my ($timer) = @_;
        return unless $timer;
        eval { $timer->stop };
        eval { $loop->remove($timer) };
    };

    $finish = sub {
        return if $state->{finalized};
        return unless $state->{child_done};
        return unless $state->{pipe_eof} || $state->{timed_out};

        $state->{finalized} = 1;

        $remove_timer->($timeout_timer);
        $remove_timer->($kill_timer);
        $remove_timer->($reap_timer);
        eval { $loop->remove($stream) } if $stream;
        eval { close $pipe };

        my $country = 'N/A';

        unless ($state->{timed_out} || $state->{wait_failed}) {
            my $status = $state->{wait_status} // 0;
            my $signal = $status & 127;
            my $exit   = ($status >> 8) & 255;

            if (!$signal && $exit == 0) {
                my $candidate = $state->{output} // '';
                $candidate =~ s/[\r\n]+\z//;
                $candidate =~ s/^\s+|\s+$//g;
                $country = $candidate
                    if $candidate ne '' && length($candidate) <= 128;
            }
        }

        my $callback_ok = eval { $callback->($country); 1; };
        if (!$callback_ok && $self && $self->{logger}) {
            my $error = $@ || 'unknown callback failure';
            $error =~ s/\s+/ /g;
            $self->{logger}->log(1, "whereis_async callback failed: $error");
        }

        # Break lexical callback cycles after completion.
        $finish        = undef;
        $schedule_reap = undef;
    };

    $schedule_reap = sub {
        return if $state->{finalized} || $state->{child_done};
        return if $reap_timer;

        $reap_timer = IO::Async::Timer::Countdown->new(
            delay     => 0.05,
            on_expire => sub {
                my $expired = $reap_timer;
                $reap_timer = undef;
                $remove_timer->($expired);

                return if $state->{finalized};

                my $waited = waitpid($child_pid, WNOHANG);

                if ($waited == $child_pid) {
                    $state->{wait_status} = $?;
                    $state->{child_done}  = 1;
                    $finish->();
                    return;
                }

                if ($waited == -1) {
                    $state->{wait_failed} = 1;
                    $state->{child_done}  = 1;
                    $finish->();
                    return;
                }

                $schedule_reap->();
            },
        );

        $loop->add($reap_timer);
        $reap_timer->start;
    };

    $timeout_timer = IO::Async::Timer::Countdown->new(
        delay     => $timeout,
        on_expire => sub {
            return if $state->{finalized};

            $state->{timed_out} = 1;

            unless ($state->{term_sent}) {
                kill 'TERM', $child_pid;
                $state->{term_sent} = 1;
            }

            $schedule_reap->();

            $kill_timer = IO::Async::Timer::Countdown->new(
                delay     => 0.2,
                on_expire => sub {
                    return if $state->{finalized} || $state->{child_done};

                    my $waited = waitpid($child_pid, WNOHANG);

                    if ($waited == $child_pid) {
                        $state->{wait_status} = $?;
                        $state->{child_done}  = 1;
                        $finish->();
                        return;
                    }

                    if ($waited == -1) {
                        $state->{wait_failed} = 1;
                        $state->{child_done}  = 1;
                        $finish->();
                        return;
                    }

                    unless ($state->{kill_sent}) {
                        kill 'KILL', $child_pid;
                        $state->{kill_sent} = 1;
                    }

                    $schedule_reap->();
                },
            );

            $loop->add($kill_timer);
            $kill_timer->start;
        },
    );

    $loop->add($timeout_timer);
    $timeout_timer->start;

    $stream = IO::Async::Stream->new(
        read_handle => $pipe,
        on_read     => sub {
            my ($io, $buffref, $eof) = @_;

            if (length $$buffref) {
                my $remaining = 256 - length($state->{output});
                $state->{output} .= substr($$buffref, 0, $remaining)
                    if $remaining > 0;
                $$buffref = '';
            }

            if ($eof && !$state->{pipe_eof}++) {
                eval { $loop->remove($io) };
                $schedule_reap->();
            }

            return 0;
        },
    );

    $loop->add($stream);
    return 1;
}
1;
