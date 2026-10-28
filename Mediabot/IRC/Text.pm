package Mediabot::IRC::Text;

use strict;
use warnings;
use utf8;
use Exporter 'import';
use Encode ();
use Mediabot::IRC::TextBudget ();

our @EXPORT_OK = qw(decode_irc_text redact_service_secret sanitize_line);

# Decode valid UTF-8 once, retaining invalid legacy bytes and the source scalar.
sub decode_irc_text {
    my ($text) = @_;

    return undef unless defined $text;
    return $text if ref $text;
    return $text if utf8::is_utf8($text);

    my $decoded = eval {
        Encode::decode(
            'UTF-8',
            $text,
            Encode::FB_CROAK() | Encode::LEAVE_SRC(),
        );
    };

    return (!$@ && defined $decoded) ? $decoded : $text;
}

sub _redact_irc_service_secret_for_log {
    use feature 'unicode_strings';
    my ($msg) = @_;

    return $msg unless defined($msg) && $msg ne '';

    my $log_msg = $msg;

    if ($log_msg =~ /^\s*(identify|id|login|register|auth|ghost|recover|release|set\s+password)\b/i) {
        # Normalize only recognized log copies, before whitespace tokenization.
        $log_msg =~ s/^\s+//;
        my @parts = split /\s+/, $log_msg;
        my $verb = lc($parts[0] // '');

        if ($verb eq 'identify' || $verb eq 'id') {
            if (@parts >= 3) { $parts[-1] = '****'; }
            elsif (@parts >= 2) { $parts[1] = '****'; }
        }
        elsif ($verb eq 'login' || $verb eq 'auth'
            || $verb eq 'ghost' || $verb eq 'recover' || $verb eq 'release')
        {
            $parts[2] = '****' if @parts >= 3;
        }
        elsif ($verb eq 'set' && lc($parts[1] // '') eq 'password') {
            $parts[2] = '****' if @parts >= 3;
        }
        else {
            # register <pass> <email> : pass is arg #1, email is not secret
            $parts[1] = '****' if @parts >= 2;
        }

        $log_msg = join(' ', @parts);
    }

    return $log_msg;
}

sub redact_service_secret { return _redact_irc_service_secret_for_log(@_); }
sub sanitize_line { return Mediabot::IRC::TextBudget::_sanitize_irc_text(@_); }

1;
