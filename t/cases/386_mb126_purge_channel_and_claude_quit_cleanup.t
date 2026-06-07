# t/cases/386_mb126_purge_channel_and_claude_quit_cleanup.t
use strict;
use warnings;
use FindBin qw($Bin);
use File::Spec;

my $case = sub {
    my ($assert) = @_;
    my $root = File::Spec->catdir($Bin, '..', '..');

    my $cc_file = File::Spec->catfile($root, 'Mediabot', 'ChannelCommands.pm');
    open my $cfh, '<', $cc_file or do { $assert->(0, "cannot open ChannelCommands.pm: $!"); return; };
    my $cc = do { local $/; <$cfh> };
    close $cfh;

    $assert->($cc =~ /purgeChannel_ctx\(\): cleared runtime caches/, 'purgeChannel_ctx logs runtime cache cleanup');

    for my $cache (qw(_badword_cache _af_params _chan_flood _chan_flood_conf _cmd_cooldown _cmd_cooldown_conf _chanset_cache _uchan_level_cache)) {
        $assert->($cc =~ /\Q$cache\E/, "purgeChannel_ctx references $cache");
    }

    $assert->($cc =~ /gethChannelNicks/ && $cc =~ /sethChannelNicks/, 'purgeChannel_ctx clears in-memory channel nicklist');

    my $pl_file = File::Spec->catfile($root, 'mediabot.pl');
    open my $pfh, '<', $pl_file or do { $assert->(0, "cannot open mediabot.pl: $!"); return; };
    my $pl = do { local $/; <$pfh> };
    close $pfh;

    $assert->($pl =~ /sub\s+purge_claude_session_for_nick\b/, 'purge_claude_session_for_nick helper exists');
    $assert->($pl =~ /my\s+\$hist_prefix\s*=\s*"\$nick\\x00"/, 'Claude cleanup history prefix uses raw nick');
    $assert->($pl =~ /my\s+\$persona_prefix\s*=\s*lc\(\$nick\)\s*\.\s*"\\x00"/, 'Claude cleanup persona prefix uses lower-case nick');
    $assert->($pl =~ /delete\s+\$bot->\{_claude_history\}/, 'Claude cleanup deletes history entries');
    $assert->($pl =~ /delete\s+\$bot->\{_claude_persona\}/, 'Claude cleanup deletes persona entries');
    $assert->($pl =~ /delete\s+\$bot->\{_ai_last_active\}/, 'Claude cleanup deletes activity TTL entries');
    $assert->($pl =~ /purge_claude_session_for_nick\(\$mediabot,\s*\$old_nick\)/, 'NICK handler purges old nick Claude state');
    $assert->($pl =~ /purge_claude_session_for_nick\(\$mediabot,\s*\$sNick\)/, 'QUIT handler purges nick Claude state');
    $assert->($pl !~ /my\s+\$prefix\s*=\s*lc\(\$sNick\)\s*\.\s*"\\x00"/, 'old QUIT lc(nick) history-only cleanup is gone');
    $assert->($pl !~ /my\s+\$prefix\s*=\s*lc\(\$sNick_n\)\s*\.\s*"\\x00"/, 'old NICK lc(nick) history-only cleanup is gone');
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
