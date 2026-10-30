package Mediabot::External::Country;

use strict;
use warnings;
use utf8;
use Exporter 'import';
use Socket ();
use JSON::MaybeXS ();
use HTTP::Tiny;
use Mediabot::AsyncWorker ();

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


# Keep country lookup policy here; AsyncWorker owns the process, protocol,
# timeout, escalation and reaping. No bot/DB/IRC object enters the child lookup.
sub whereis_async {
    my ($self, $sHostname, $callback, %opts) = @_;
    return 0 unless ref($callback) eq 'CODE';

    my $timeout = $opts{timeout};
    $timeout = 5 unless defined($timeout) && !ref($timeout)
        && $timeout =~ /\A\d+(?:\.\d+)?\z/;
    $timeout = 0.1 if $timeout < 0.1;
    $timeout = 15 if $timeout > 15;
    my $loop = eval { $self->getLoop };
    $loop ||= $self->{loop} if ref($self);

    # Preserve the explicit no-loop compatibility path. Worker launch failures
    # below must never retry blocking DNS/HTTP in the IRC parent.
    unless ($loop && $loop->can('add') && $loop->can('remove')) {
        my $country = eval { _compat_whereis($self, $sHostname) };
        $country = 'N/A' unless defined($country) && !ref($country) && $country ne '';
        eval { $callback->($country); 1 };
        return 1;
    }

    my $finished = 0;
    my $done = sub {
        my ($result) = @_;
        return if $finished++;
        my $country = 'N/A';
        if (ref($result) eq 'HASH' && $result->{ok} && ref($result->{value}) eq 'HASH') {
            my $candidate = $result->{value}{country};
            if (defined($candidate) && !ref($candidate) && length($candidate) <= 128) {
                $candidate =~ s/^\s+|\s+$//g;
                $country = $candidate if $candidate ne '';
            }
        }
        my $run = $callback;
        undef $callback;
        my $ok = eval { $run->($country); 1 };
        if (!$ok && $self->{logger}) {
            my $error = $@ || 'unknown callback failure';
            $error =~ s/\s+/ /g;
            eval { $self->{logger}->log(1, "whereis_async callback failed: $error") };
        }
    };
    my $worker = eval { Mediabot::AsyncWorker->start(
        loop => $loop, label => 'country lookup', timeout => $timeout,
        term_grace => 0.2, force_grace => 1, max_output => 1024,
        child => sub {
            my $country = _compat_whereis({}, $sHostname);
            $country = 'N/A' unless defined($country) && !ref($country) && $country ne '';
            return { country => substr($country, 0, 128) };
        },
        on_done => $done,
    ) };
    $done->({ ok => 0, error => 'worker_setup' }) unless $worker;
    return 1;
}

1;
