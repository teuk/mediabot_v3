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
            $dcc->{ctcp}    = 1;
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
            $dcc->{ctcp}    = 1;
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
        $stripped->{ctcp}    = 0;
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
    unless ($payload =~ /^CHAT\s+chat\s+(\d+)\s+(\d+)(?:\s+(\d+))?\s*$/i) {
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

1;

__END__

=head1 NAME

Mediabot::DCC - Pure DCC and CTCP parsing helpers for Mediabot v3

=head1 DESCRIPTION

This module parses CTCP CHAT and DCC CHAT payloads. It contains no network code.

It exists to keep fragile DCC parsing out of C<mediabot.pl> and make the
supported formats easy to test.

=cut
