use strict;
use warnings;
use FindBin qw($Bin);
use File::Spec;

sub _slurp_mb386 {
    my ($path) = @_;
    open my $fh, '<', $path or die "cannot open $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_mb386 {
    my ($src, $start, $next) = @_;
    return $1 if $src =~ /(sub\s+\Q$start\E\s*\{.*?)(?=\nsub\s+\Q$next\E\s*\{)/s;
    return;
}

my $case = sub {
    my ($assert) = @_;

    my $root = File::Spec->catdir($Bin, '..', '..');
    my $file = File::Spec->catfile($root, 'Mediabot', 'Helpers.pm');
    my $src = _slurp_mb386($file);

    my $sanitize = _extract_mb386(
        $src, '_sanitize_irc_text', '_redact_irc_service_secret_for_log'
    );
    my $redact = _extract_mb386(
        $src, '_redact_irc_service_secret_for_log', '_split_text_for_irc'
    );
    my $split = _extract_mb386($src, '_split_text_for_irc', 'botPrivmsg');
    my $privmsg = _extract_mb386($src, 'botPrivmsg', 'botAction');
    my $action = _extract_mb386($src, 'botAction', 'botNotice');
    my $notice = _extract_mb386($src, 'botNotice', 'joinChannel');

    $assert->(defined $sanitize, 'shared outbound sanitizer extracted');
    $assert->(defined $redact, 'private credential redactor extracted');
    $assert->(defined $split, 'IRC splitter extracted');
    $assert->(defined $privmsg && defined $action && defined $notice,
        'three outbound helper bodies extracted');
    return unless defined $sanitize && defined $redact && defined $split
        && defined $privmsg && defined $action && defined $notice;

    my $ok = eval qq{
        package MB386::Harness;
        use strict;
        use warnings;
        $sanitize
        $redact
        1;
    };
    $assert->($ok, 'sanitizer and redactor compile in isolation');
    return unless $ok;

    my $normal = 'ordinary text';
    $assert->(MB386::Harness::_sanitize_irc_text($normal) eq $normal,
        'ordinary outbound text is unchanged');

    my $forged = "hello\r\n[ERROR] forged\0tail\nnext";
    my $clean = MB386::Harness::_sanitize_irc_text($forged);
    $assert->($clean eq 'hello [ERROR] forged tail next',
        'CR, LF and NUL runs are flattened to spaces');
    $assert->($clean !~ /[\r\n\x00]/,
        'sanitized text contains no line-control byte');

    my $service = MB386::Harness::_sanitize_irc_text(
        "identify account\r\nSWORD-FISH-386"
    );
    my $safe = MB386::Harness::_redact_irc_service_secret_for_log($service);
    $assert->(index($safe, 'SWORD-FISH-386') < 0 && index($safe, '****') >= 0,
        'sanitization before redaction still masks multiline service secrets');

    for my $entry (
        [botPrivmsg => $privmsg, qr/\$sMsg\s*=\s*_sanitize_irc_text\(\$sMsg\)/],
        [botAction  => $action,  qr/\$sMsg\s*=\s*_sanitize_irc_text\(\$sMsg\)/],
        [botNotice  => $notice,  qr/\$text\s*=\s*_sanitize_irc_text\(\$text\)/],
    ) {
        my ($name, $body, $pattern) = @$entry;
        $assert->($body =~ $pattern, "$name invokes the shared sanitizer");
        $assert->($body !~ /s\/\[\\r\\n\]\+\/ \/g/,
            "$name no longer carries a CR/LF-only inline sanitizer");
    }

    $assert->(index($privmsg, '$sMsg = _sanitize_irc_text($sMsg)')
            < index($privmsg, 'my $eventtype'),
        'botPrivmsg sanitizes before channel/private logs and history');
    $assert->(index($action, '$sMsg = _sanitize_irc_text($sMsg)')
            < index($action, 'my $eventtype'),
        'botAction sanitizes before channel/private logs and history');
    $assert->(index($notice, '$text = _sanitize_irc_text($text)')
            < index($notice, 'my $is_channel_target'),
        'botNotice sanitizes before target-specific logging');
    $assert->($split =~ /_sanitize_irc_text\(\$text\)/,
        'IRC splitter keeps defence-in-depth sanitization');
    $assert->($src =~ /mb386-B1/,
        'MB386 source marker is present');
};

if (caller) { return $case; }

my ($tests, $fail) = (0, 0);
my $assert = sub {
    my ($ok, $name) = @_;
    $tests++;
    $name = 'unnamed assertion' unless defined $name && $name ne '';
    if ($ok) { print "ok $tests - $name\n"; }
    else { print "not ok $tests - $name\n"; $fail++; }
};

$case->($assert);
print "1..$tests\n";
exit($fail ? 1 : 0);
