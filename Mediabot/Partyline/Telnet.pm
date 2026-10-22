package Mediabot::Partyline::Telnet;

use strict;
use warnings;
use Exporter 'import';

our @EXPORT_OK = qw(decode_input);

# Filter framing only: ECHO policy and command/line semantics belong to callers.
# Each connection owns its state hash. Subnegotiation payload is never retained.
# Modes: 0=data, 1=IAC, 2=option byte, 3=subnegotiation, 4=IAC in subnegotiation.
sub decode_input {
    my ($state, $data) = @_;
    return '' unless defined($data) && length($data);

    my $mode = $state->{mode} // 0;
    my $out = '';
    my $pos = 0;
    my $length = length($data);
    while ($pos < $length) {
        if ($mode == 0) {
            my $iac = index($data, "\xff", $pos);
            if ($iac < 0) {
                $out .= substr($data, $pos);
                last;
            }
            $out .= substr($data, $pos, $iac - $pos);
            $pos = $iac + 1;
            $mode = 1;
            next;
        }
        my $byte = substr($data, $pos++, 1);
        if ($mode == 1) {
            if ($byte eq "\xff") { $out .= $byte; $mode = 0 }
            elsif ($byte ge "\xfb" && $byte le "\xfe") { $mode = 2 }
            elsif ($byte eq "\xfa") { $mode = 3 }
            elsif ($byte ge "\xf0" && $byte le "\xf9") { $mode = 0 }
            else { $out .= "\xff" . $byte; $mode = 0 } # Preserve unknown pairs.
        }
        elsif ($mode == 2) { $mode = 0 }
        elsif ($mode == 3) { $mode = 4 if $byte eq "\xff" }
        else { $mode = $byte eq "\xf0" ? 0 : 3 }
    }
    $state->{mode} = $mode;
    return $out;
}

1;
