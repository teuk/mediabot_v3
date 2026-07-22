# =============================================================================
# MB384 regression:
# - inbound private commands must not leak credentials in normal/debug logs;
# - reversible hex dumps must not expose private payloads or DCC tokens;
# - IRC channel prefixes #, &, ! and + remain public targets.
# =============================================================================

use strict;
use warnings;
use utf8;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use Encode qw(encode);
use File::Spec;

sub _slurp_mb384 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_mb384 {
    my ($src, $name) = @_;

    return undef unless $src =~ /^sub\s+\Q$name\E\s*\{/mg;

    my $begin = $-[0];
    my $pos   = pos($src);
    my $depth = 1;
    my $len   = length($src);

    while ($pos < $len) {
        my $char = substr($src, $pos, 1);
        $depth++ if $char eq '{';
        $depth-- if $char eq '}';

        return substr($src, $begin, $pos + 1 - $begin)
            if $depth == 0;

        $pos++;
    }

    return undef;
}

return sub {
    my ($assert) = @_;

    my $main = _slurp_mb384(File::Spec->catfile('.', 'mediabot.pl'));

    my $channel_sub = _extract_sub_mb384($main, '_irc_target_is_channel');
    my $summary_sub = _extract_sub_mb384($main, '_private_payload_log_summary');
    my $secret_sub  = _extract_sub_mb384($main, '_private_message_is_sensitive');

    $assert->ok(defined $channel_sub, 'shared IRC channel-target helper exists');
    $assert->ok(defined $summary_sub, 'private payload summary helper exists');
    $assert->ok(defined $secret_sub, 'private credential-command detector exists');

    my $eval_ok = eval qq{
        package MB384::Harness;
        use strict;
        use warnings;
        use utf8;
        use Encode qw(encode);
        $channel_sub
        $summary_sub
        $secret_sub
        1;
    };
    $assert->ok($eval_ok, 'MB384 helpers compile in isolation');

    for my $target ('#chan', '&local', '!safe', '+modeless') {
        $assert->ok(
            MB384::Harness::_irc_target_is_channel($target),
            "$target is recognized as an IRC channel target"
        );
    }
    $assert->ok(
        !MB384::Harness::_irc_target_is_channel('Te[u]K'),
        'a nickname is not classified as a channel'
    );

    my $secret = 'login teuk SuperSecret42';
    my $summary = MB384::Harness::_private_payload_log_summary($secret);
    $assert->like($summary, qr/^\[private payload redacted bytes=\d+\]$/,
        'private payload summary exposes only a byte count');
    $assert->unlike($summary, qr/SuperSecret42|login|teuk/,
        'private payload summary contains no command, account or password');

    my $utf8_summary = MB384::Harness::_private_payload_log_summary("pass éé");
    $assert->like($utf8_summary, qr/bytes=9\]/,
        'private payload summary counts UTF-8 wire bytes');

    for my $line (
        'login user pass',
        '  register user pass',
        'pass old new',
        'newpass secret',
        'identify nick secret',
        'auth user secret',
        'xlogin user secret',
        'set password secret',
    ) {
        $assert->ok(
            MB384::Harness::_private_message_is_sensitive($line),
            "credential command is sensitive: $line"
        );
    }

    $assert->ok(
        !MB384::Harness::_private_message_is_sensitive('passive mode'),
        'command matching is exact and does not hide passive by prefix'
    );
    $assert->ok(
        !MB384::Harness::_private_message_is_sensitive('hello there'),
        'ordinary private text remains eligible for normal LIVE logging'
    );

    my $private_body = _extract_sub_mb384($main, 'on_private') // '';
    $assert->like($private_body, qr/_private_payload_log_summary\(\$what\)/,
        'generic private callback logs only a redacted summary');
    $assert->unlike(
        $private_body,
        qr/log\(2,\s*"on_private\(\) -\$who- \$what"\)/,
        'generic private callback no longer uses the historical raw-text log'
    );

    my $privmsg_body = _extract_sub_mb384($main, '_on_message_PRIVMSG_body') // '';
    $assert->like(
        $privmsg_body,
        qr/redact_last_arg\s*=>\s*\(\$is_channel\s*\?\s*0\s*:\s*1\)/,
        'private PRIVMSG debug args redact the payload while channel args remain visible'
    );
    $assert->like($privmsg_body, qr/if \(\$is_channel\) \{/,
        'PRIVMSG public/private routing uses RFC channel-prefix detection');
    $assert->unlike($privmsg_body, qr/what_hex|unpack\('H\*',\s*\$what/,
        'private-message diagnostics no longer emit reversible hex payloads');
    $assert->like($privmsg_body, qr/_private_message_is_sensitive\(\$what\)/,
        'LIVE private logging uses the exact credential-command guard');

    my $dcc_body = _extract_sub_mb384($main, 'on_message_ctcp_DCC') // '';
    $assert->unlike($dcc_body, qr/raw_message_hex|unpack\('H\*'/,
        'DCC debug path no longer emits raw reversible hex');
    $assert->unlike($dcc_body, qr/CTCP DCC from .*\$payload/,
        'DCC log no longer interpolates the raw payload/token');
    $assert->like($dcc_body, qr/token_present=\$token_present/,
        'DCC log keeps a non-secret token-presence diagnostic');
    $assert->like($dcc_body, qr/_private_payload_log_summary\(\$raw\)/,
        'optional raw-message diagnostics are reduced to a safe summary');

    $assert->unlike($main, qr/\[DCC_DEBUG\]\s+what_hex=/,
        'legacy private payload hex marker is gone');
    $assert->unlike($main, qr/\[CTCP_DCC_DEBUG\]\s+raw_message_hex=/,
        'legacy raw DCC message hex marker is gone');
    $assert->like($main, qr/mb384-B1/,
        'MB384 private-log redaction marker is present');
};
