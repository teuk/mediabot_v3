package Mediabot::Partyline::Presence;

use strict;
use warnings;
use Exporter 'import';
use Encode qw(encode decode FB_CROAK LEAVE_SRC);
use Mediabot::IRC::TextBudget qw(_irc_wire_bytes);

our @EXPORT_OK = qw(_cmd_away _cmd_back);

# Presence belongs to one authenticated connection, never to the SQL account.
# Keep reasons as validated UTF-8 wire bytes for IO::Async and .whom output.
sub _cmd_away {
    my ($self, $stream, $id, $arg) = @_;
    my $session = $self->{users}{$id};
    unless ($session && $session->{authenticated}) {
        $stream->write("Authentication required.\r\n");
        return;
    }

    my $reason = $arg // '';
    $reason =~ s/^[ \t]+|[ \t]+$//g;
    $reason = 'Away' if $reason eq '';
    my $text = utf8::is_utf8($reason) ? $reason
        : eval { decode('UTF-8', $reason, FB_CROAK | LEAVE_SRC) };
    unless (defined($text) && $text !~ /[\x00-\x1f\x7f-\x9f]/
            && _irc_wire_bytes($reason) <= 160) {
        $stream->write("Usage: .away [reason] (valid UTF-8, no control characters, max 160 bytes)\r\n");
        return;
    }
    $reason = encode('UTF-8', $text);
    if (defined($session->{away}) && $session->{away} eq $reason) {
        $stream->write("Already away: $reason\r\n");
        return;
    }
    $session->{away} = $reason;
    $stream->write("Marked away: $reason\r\n");
    $self->_broadcast("*** " . $self->_display_nick($id) . " is away: $reason ***", $id);
}

sub _cmd_back {
    my ($self, $stream, $id, $arg) = @_;
    my $session = $self->{users}{$id};
    unless ($session && $session->{authenticated}) {
        $stream->write("Authentication required.\r\n");
        return;
    }
    if (defined($arg) && $arg =~ /\S/) {
        $stream->write("Usage: .back\r\n");
        return;
    }
    unless (exists $session->{away}) {
        $stream->write("You are already back.\r\n");
        return;
    }
    delete $session->{away};
    $stream->write("You are back.\r\n");
    $self->_broadcast("*** " . $self->_display_nick($id) . " is back. ***", $id);
}

1;
