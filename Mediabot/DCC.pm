package Mediabot::DCC;

use strict;
use warnings;
use Exporter 'import';

our @EXPORT_OK = qw(
    strip_ctcp_delimiters
    parse_ctcp_payload
    parse_dcc_payload
    parse_dcc_chat_payload
    is_ctcp_chat
    is_dcc_chat
    is_dcc_active
    is_dcc_passive
    ip_int_to_ipv4
    validate_dcc_active_target
);

# =============================================================================
# Mediabot::DCC
#
# Pure DCC/CTCP parsing helpers.
#
# This module does not send IRC messages and does not open sockets.
# It only normalizes and parses payloads so mediabot.pl does not have to carry
# fragile DCC/CTCP regex logic inline.
# =============================================================================

sub strip_ctcp_delimiters {
    my ($payload) = @_;

    return '' unless defined $payload;

    # Trim first because some clients/wrappers may leave whitespace around
    # the CTCP delimiters, then remove the delimiters, then trim again.
    $payload =~ s/^\s+|\s+$//g;
    $payload =~ s/^\x01//;
    $payload =~ s/\x01$//;
    $payload =~ s/^\s+|\s+$//g;

    return $payload;
}

sub parse_ctcp_payload {
    my ($payload) = @_;

    my $was_ctcp = (defined($payload) && $payload =~ /^\x01.*\x01$/s) ? 1 : 0;

    my $clean = strip_ctcp_delimiters($payload);

    return {
        type    => 'empty',
        raw     => $payload,
        payload => $clean,
    } if $clean eq '';

    # Eggdrop-style:
    #   /ctcp <botnick> CHAT
    # delivered by some clients as:
    #   \x01CHAT\x01
    # but some clients send the full DCC payload without the leading "DCC":
    #   \x01CHAT chat <ip_int> <port>\x01
    # Try parsing as DCC first, fall back to bare ctcp_chat.
    if ($clean =~ /^CHAT(?:\s|$)/i) {
        my $dcc = parse_dcc_chat_payload($clean);
        if ($dcc->{type} ne 'invalid') {
            $dcc->{raw}     = $payload;
            $dcc->{payload} = $clean;
            $dcc->{ctcp}    = $was_ctcp;
            return $dcc;
        }
        # Bare /ctcp CHAT with no payload
        return {
            type    => 'ctcp_chat',
            raw     => $payload,
            payload => $clean,
        };
    }

    # Full raw CTCP DCC CHAT:
    #   \x01DCC CHAT chat <ip_int> <port>\x01
    #   \x01DCC CHAT chat 0 0 <token>\x01
    if ($clean =~ /^DCC\s+(.+)$/i) {
        my $inner = $1;
        my $dcc = parse_dcc_chat_payload($inner);

        if ($dcc->{type} ne 'invalid') {
            $dcc->{raw}     = $payload;
            $dcc->{payload} = $clean;
            $dcc->{ctcp}    = $was_ctcp;
            return $dcc;
        }
    }

    # Net::Async::IRC or another layer may strip the CTCP marker and/or the
    # leading DCC token before the private-message handler receives it:
    #   CHAT chat <ip_int> <port>
    #   CHAT chat 0 0 <token>
    my $stripped = parse_dcc_chat_payload($clean);
    if ($stripped->{type} ne 'invalid') {
        $stripped->{raw}     = $payload;
        $stripped->{payload} = $clean;
        $stripped->{ctcp}    = $was_ctcp;
        return $stripped;
    }

    return {
        type    => 'private_command',
        raw     => $payload,
        payload => $clean,
    };
}

sub parse_dcc_payload {
    my ($payload) = @_;

    $payload = '' unless defined $payload;
    $payload = strip_ctcp_delimiters($payload);
    $payload =~ s/^\s+|\s+$//g;

    # Accept both:
    #   DCC CHAT chat <ip_int> <port>
    #   CHAT chat <ip_int> <port>
    $payload =~ s/^DCC\s+//i;

    my $dcc = parse_dcc_chat_payload($payload);
    $dcc->{payload} = $payload if ref($dcc) eq 'HASH';

    return $dcc;
}


sub parse_dcc_chat_payload {
    my ($payload) = @_;

    $payload = '' unless defined $payload;
    $payload =~ s/^\s+|\s+$//g;

    # DCC CHAT format after removing leading DCC, or after Net::Async::IRC
    # stripping the DCC token:
    #   CHAT chat <ip_int> <port>
    #   CHAT chat 0 0 <token>
    #
    # mb142-B2: le token de passive DCC est OPAQUE et est typiquement
    # alphanumerique/hex chez les clients modernes (mIRC, HexChat, irssi,
    # KVIrc). Avant ce fix, on n'acceptait que `(\d+)` ce qui rejetait
    # les tokens hex et marquait le payload comme 'invalid', cassant
    # silencieusement le DCC CHAT passive de la majorite des clients.
    # Le token reste valide pour un set de chars safe (alphanumerique +
    # '._-' usuels dans les ID generes).
    unless ($payload =~ m{^CHAT\s+chat\s+(\d+)\s+(\d+)(?:\s+([A-Za-z0-9._-]+))?\s*$}i) {
        return {
            type    => 'invalid',
            payload => $payload,
        };
    }

    my ($ip_int, $port, $token) = ($1, $2, $3);

    # Passive DCC CHAT: ip_int == 0 AND port == 0 (token is optional but
    # usually present). A non-zero ip/port with a trailing token is NOT passive
    # — it is a malformed or extended active offer; treat it as active.
    my $mode = 'active';
    if (defined($ip_int) && defined($port) && $ip_int == 0 && $port == 0) {
        $mode = 'passive';
    }

    return {
        type   => 'dcc_chat',
        mode   => $mode,
        ip_int => $ip_int,
        port   => $port,
        token  => $token,
    };
}

sub is_ctcp_chat {
    my ($parsed) = @_;
    return 0 unless ref($parsed) eq 'HASH';
    return ($parsed->{type} || '') eq 'ctcp_chat' ? 1 : 0;
}

sub is_dcc_chat {
    my ($parsed) = @_;
    return 0 unless ref($parsed) eq 'HASH';
    return ($parsed->{type} || '') eq 'dcc_chat' ? 1 : 0;
}

sub is_dcc_active {
    my ($parsed) = @_;
    return 0 unless is_dcc_chat($parsed);
    return ($parsed->{mode} || '') eq 'active' ? 1 : 0;
}

sub is_dcc_passive {
    my ($parsed) = @_;
    return 0 unless is_dcc_chat($parsed);
    return ($parsed->{mode} || '') eq 'passive' ? 1 : 0;
}


sub ip_int_to_ipv4 {
    my ($ip_int) = @_;

    return undef unless defined $ip_int;
    return undef unless $ip_int =~ /^\d+$/;

    # Keep this conservative. DCC IPv4 integers are unsigned 32-bit values.
    return undef if $ip_int < 0;
    return undef if $ip_int > 4294967295;

    return join(
        '.',
        (($ip_int >> 24) & 255),
        (($ip_int >> 16) & 255),
        (($ip_int >> 8)  & 255),
        ($ip_int & 255),
    );
}

# validate_dcc_active_target($ip_int, $port)
#
# MB332-B1: active DCC CHAT asks the bot to open an outbound TCP connection to
# an address supplied by IRC. Validate that destination centrally before any
# socket is opened. Private, loopback, link-local, carrier-grade NAT,
# documentation, benchmark, multicast and reserved destinations are rejected
# so DCC cannot be used as an SSRF/port-scanning primitive against networks
# reachable from the bot host.
#
# Returns: (ok, dotted_ipv4_or_undef, reason)
sub validate_dcc_active_target {
    my ($ip_int, $port) = @_;

    my $ip = ip_int_to_ipv4($ip_int);
    return (0, undef, 'invalid_ipv4_integer') unless defined $ip;

    return (0, $ip, 'invalid_port')
        unless defined($port)
            && !ref($port)
            && $port =~ /^\d+$/
            && $port >= 1024
            && $port <= 65535;

    my @octet = split /\./, $ip;
    return (0, $ip, 'invalid_ipv4') unless @octet == 4;

    my ($a, $b, $c, $d) = @octet;

    return (0, $ip, 'unspecified')     if $a == 0;
    return (0, $ip, 'private')         if $a == 10;
    return (0, $ip, 'shared_cgnat')    if $a == 100 && $b >= 64 && $b <= 127;
    return (0, $ip, 'loopback')        if $a == 127;
    return (0, $ip, 'link_local')      if $a == 169 && $b == 254;
    return (0, $ip, 'private')         if $a == 172 && $b >= 16 && $b <= 31;
    return (0, $ip, 'ietf_protocol')   if $a == 192 && $b == 0 && $c == 0;
    return (0, $ip, 'documentation')   if $a == 192 && $b == 0 && $c == 2;
    return (0, $ip, 'private')         if $a == 192 && $b == 168;
    return (0, $ip, 'deprecated_6to4') if $a == 192 && $b == 88 && $c == 99;
    return (0, $ip, 'benchmark')       if $a == 198 && ($b == 18 || $b == 19);
    return (0, $ip, 'documentation')   if $a == 198 && $b == 51 && $c == 100;
    return (0, $ip, 'documentation')   if $a == 203 && $b == 0 && $c == 113;
    return (0, $ip, 'multicast')       if $a >= 224 && $a <= 239;
    return (0, $ip, 'reserved')        if $a >= 240;

    return (1, $ip, 'ok');
}

1;

__END__

=head1 NAME

Mediabot::DCC - Pure DCC and CTCP parsing helpers for Mediabot v3

=head1 DESCRIPTION

This module parses CTCP CHAT and DCC CHAT payloads. It contains no network code.

It exists to keep fragile DCC parsing out of C<mediabot.pl> and make the
supported formats easy to test.

=cut
