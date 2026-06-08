# t/cases/394_mb135_channel_target_and_badword_finish.t
use strict;
use warnings;
use FindBin qw($Bin);
use File::Spec;

my $case = sub {
    my ($assert) = @_;

    my $root = File::Spec->catdir($Bin, '..', '..');
    my $helpers_file = File::Spec->catfile($root, 'Mediabot', 'Helpers.pm');

    open my $hfh, '<', $helpers_file
        or do { $assert->(0, "cannot open Helpers.pm: $!"); return; };
    my $src = do { local $/; <$hfh> };
    close $hfh;

    $assert->($src =~ /sub\s+_is_irc_channel_target\b/,
        '_is_irc_channel_target helper exists');
    $assert->($src =~ /return defined\(\$target\) && \$target =~ \/\^\[#&!\+\]\//,
        '_is_irc_channel_target recognizes # & ! + prefixes');

    my $privmsg_block = ($src =~ /sub botPrivmsg \{(.*?)sub botAction \{/s) ? $1 : '';
    my $action_block  = ($src =~ /sub botAction \{(.*?)sub botNotice \{/s) ? $1 : '';
    my $notice_block  = ($src =~ /sub botNotice \{(.*?)sub joinChannel \{/s) ? $1 : '';

    $assert->($privmsg_block =~ /if \(_is_irc_channel_target\(\$sTo\)\) \{/,
        'botPrivmsg uses shared channel target detection');
    $assert->($action_block =~ /if \(_is_irc_channel_target\(\$sTo\)\) \{/,
        'botAction uses shared channel target detection');
    $assert->($notice_block =~ /_is_irc_channel_target\(\$target\)\s*\?\s*\$chunk\s*:\s*_redact_irc_service_secret_for_log\(\$chunk\)/s,
        'botNotice uses shared channel target detection for private redaction');
    $assert->($notice_block =~ /if \(_is_irc_channel_target\(\$target\)\) \{/,
        'botNotice uses shared channel target detection for action log');

    $assert->($privmsg_block !~ /if \(\$sTo =~ \/\^#\//,
        'botPrivmsg old # only detection is gone');
    $assert->($action_block !~ /substr\(\$sTo,\s*0,\s*1\) eq '#'/,
        'botAction old # only substr detection is gone');
    $assert->($notice_block !~ /\$target =~ \/\^#\//,
        'botNotice old # only detection is gone');

    $assert->($privmsg_block =~ /mb135-B10: match botAction cleanup/,
        'botPrivmsg badword SQL error path has mb135-B10 marker');
    $assert->($privmsg_block =~ /botPrivmsg\(\) Badword SQL Error.*?\$sth->finish if \$sth/s,
        'botPrivmsg finishes statement handle on badword SQL error');
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
