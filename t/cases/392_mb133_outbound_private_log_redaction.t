# t/cases/392_mb133_outbound_private_log_redaction.t
use strict;
use warnings;
use FindBin qw($Bin);
use File::Spec;

sub _redact_for_test {
    my ($msg) = @_;
    return $msg unless defined($msg) && $msg ne '';

    my $log_msg = $msg;

    if ($log_msg =~ /^(identify|id|login|register|auth|ghost|recover|release|set\s+password)\b/i) {
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
            $parts[1] = '****' if @parts >= 2;
        }

        $log_msg = join(' ', @parts);
    }

    return $log_msg;
}

my $case = sub {
    my ($assert) = @_;

    my @cases = (
        ['identify secret',              'identify ****'],
        ['identify teuk secret',         'identify teuk ****'],
        ['id teuk secret',               'id teuk ****'],
        ['login user secret',            'login user ****'],
        ['auth user secret',             'auth user ****'],
        ['ghost nick secret',            'ghost nick ****'],
        ['recover nick secret',          'recover nick ****'],
        ['release nick secret',          'release nick ****'],
        ['register secret user@mail',    'register **** user@mail'],
        ['set password secret',          'set password ****'],
        ['normal message secret',        'normal message secret'],
    );

    for my $c (@cases) {
        my ($in, $want) = @$c;
        my $got = _redact_for_test($in);
        $assert->($got eq $want, "redact '$in' -> '$want'");
    }

    my $root = File::Spec->catdir($Bin, '..', '..');
    my $helpers_file = File::Spec->catfile($root, 'Mediabot', 'Helpers.pm');

    open my $hfh, '<', $helpers_file
        or do { $assert->(0, "cannot open Helpers.pm: $!"); return; };
    my $src = do { local $/; <$hfh> };
    close $hfh;

    $assert->($src =~ /sub\s+_redact_irc_service_secret_for_log\b/,
        'shared redaction helper exists');

    $assert->($src =~ /mb133-B7: keep outbound private-message logs safe/,
        'helper has mb133-B7 marker');

    $assert->($src =~ /my \$log_msg = _redact_irc_service_secret_for_log\(\$sMsg\);\s*\$self->\{logger\}->log\(0, "-> \*\$sTo\* \$log_msg"\);/s,
        'botPrivmsg private log uses shared helper');

    my $bot_action_block = ($src =~ /sub botAction \{(.*?)sub botNotice \{/s) ? $1 : '';
    $assert->($bot_action_block =~ /_redact_irc_service_secret_for_log\(\$sMsg\)/,
        'botAction private log uses shared helper');

    my $bot_notice_block = ($src =~ /sub botNotice \{(.*?)sub joinChannel \{/s) ? $1 : '';
    $assert->($bot_notice_block =~ /my \$safe_log_text = \$is_channel_target\s*\? \$text\s*:\s*_redact_irc_service_secret_for_log\(\$text\)/s,
        'botNotice redacts the complete private message before logging');

    $assert->($bot_notice_block =~ /text='\$safe_log_text'/,
        'botNotice debug log uses the redacted private copy');

    $assert->($bot_notice_block !~ /text='\$text'/,
        'botNotice debug log no longer prints the raw private text');

    $assert->($bot_notice_block =~ /\@private_log_chunks = _split_text_for_irc\(\$safe_log_text, 400\)/,
        'botNotice splits the already-redacted private log copy');

    $assert->($bot_notice_block =~ /logBotAction\(\$self, undef, "notice", \$self->\{irc\}->nick_folded, \$target, \$chunk\)/,
        'channel NOTICE action log still uses original chunk');
};

if (caller) { return $case; }

my $tests = 0;
my $fail  = 0;
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
