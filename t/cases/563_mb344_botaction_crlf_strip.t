# t/cases/563_mb344_botaction_crlf_strip.t
# =============================================================================
# mb344/mb386 — outbound helpers neutralise CR/LF/NUL through one shared
# sanitizer before logging, history and wire output.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;
use Encode qw(encode);

sub _slurp_563 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    my $src = _slurp_563(File::Spec->catfile('.', 'Mediabot', 'Helpers.pm'));

    my ($sanitize_text) = $src =~ /(sub _sanitize_irc_text \{.*?\n\})/s;
    my ($split_text) = $src =~ /(sub _split_text_for_irc \{.*?\n\})/s;

    my $compiled = eval qq{
        package T563;
        use Encode qw(encode);
        $sanitize_text
        $split_text
        1;
    };
    $assert->ok($compiled, 'shared sanitizer and splitter compile');
    return unless $compiled;

    my $sanitize = \&T563::_sanitize_irc_text;
    my $split    = \&T563::_split_text_for_irc;

    my $emit = sub {
        my ($msg) = @_;
        $msg = $sanitize->($msg);
        my $overhead = length("\1ACTION \1");
        my @chunks = $split->($msg, 400 - $overhead);
        @chunks = ($msg) unless @chunks;
        my @lines;
        for my $chunk (@chunks) {
            next unless defined($chunk) && $chunk ne '';
            my $payload = utf8::is_utf8($chunk)
                ? encode('UTF-8', $chunk)
                : $chunk;
            push @lines, "\1ACTION $payload\1";
        }
        return @lines;
    };

    my @lines = $emit->("slaps bob\r\nPRIVMSG #evil :owned\0QUIT");
    my $any_control = grep { /[\r\n\x00]/ } @lines;
    $assert->is($any_control, 0,
        'no emitted ACTION contains CR, LF or NUL');

    my $joined = join('', @lines);
    $assert->like($joined, qr/slaps bob/,
        'legitimate ACTION text is preserved');
    $assert->like($joined, qr/\x01ACTION .*\x01/,
        'ACTION wrapper remains intact');

    my @normal = $emit->('slaps bob around with a large trout');
    $assert->is(scalar(@normal), 1,
        'ordinary ACTION remains one IRC message');

    for my $name (qw(botPrivmsg botNotice botAction)) {
        my ($body) = $src =~ /(sub \Q$name\E \{.*?\n\}\n)/s;
        $body //= '';
        $assert->like($body, qr/_sanitize_irc_text\(\$\w+\)/,
            "$name uses the shared CR/LF/NUL sanitizer");
    }

    $assert->like($src, qr/mb386-B1/,
        'mb386-B1 marker is present');
};
