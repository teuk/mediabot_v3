#!/usr/bin/perl

use strict;
use warnings;
use Test::More;

sub slurp {
    my ($path) = @_;
    open my $fh, '<:raw', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

my $main      = slurp('mediabot.pl');
my $fullop    = slurp('Mediabot/Fullop.pm');
my $commands  = slurp('Mediabot/ChannelCommands.pm');
my $metrics   = slurp('Mediabot/Metrics.pm');
my $fresh     = slurp('install/mediabot.sql');
my $migration = slurp('install/migrations/20260903_fullop_chanset.sql');
my $mig_readme = slurp('install/migrations/README.md');
my $db_docs   = slurp('docs/DB_MIGRATIONS.md');
my $docs      = slurp('docs/FULLOP.md');
my $sample    = slurp('mediabot.sample.conf');

like($main, qr/use Mediabot::Fullop;/,
    'main process loads the Fullop engine');
like($main, qr/Mediabot::Fullop->new\(\s*bot\s*=>\s*\$mediabot,\s*channel_ban\s*=>\s*\$mediabot->\{channel_ban\}/s,
    'Fullop shares the existing persistent ChannelBan helper');

like($main, qr/on_message_005.*?update_isupport\(\@args\)/s,
    'numeric 005 feeds live ISUPPORT into Fullop');
like($main, qr/on_message_RPL_CHANNELMODEIS\s*=>\s*\\&on_message_RPL_CHANNELMODEIS/,
    'numeric 324 callback is wired');
like($main, qr/sub on_message_RPL_CHANNELMODEIS.*?remember_channel_modes\(\$channel, \$modes, \@params\)/s,
    'numeric 324 seeds parameter-bearing channel state');

like($main, qr/sub on_message_MODE.*?handle_mode\(.*?message\s*=>\s*\$message.*?prefix\s*=>.*?channel\s*=>\s*\$target_name.*?mode_string\s*=>\s*\$sModes.*?mode_args\s*=>\s*\\\@tArgs/s,
    'channel MODE events pass raw actor and parsed arguments to the guard');
like($main, qr/my \$join_is_banned = 0;.*?\$join_is_banned = 1;.*?handle_join\(\$target_name, \$sNick\)/s,
    'active persistent bans are checked before a joiner receives +o');
like($main, qr/sub on_message_RPL_ENDOFNAMES.*?sweep_channel\(\$channel, \@deduped\)/s,
    'completed NAMES replies drive the current-user op sweep');
like($main, qr/on_message_RPL_NAMEREPLY.*?names_from_blob\(\$names_blob\)/s,
    'NAMES normalization also follows server-advertised PREFIX symbols');

like($commands, qr/\$chanset =~ \/\^Fullop\$\/i.*?activate_channel\(\s*\$target_channel,\s*refresh_names\s*=>\s*1/s,
    'chanset activation starts an immediate MODE/NAMES synchronization');

like($fullop, qr/DEFAULT_BAN_SECONDS\s*=>\s*600/,
    'ten-minute sanction is the default');
like($fullop, qr/DEFAULT_REASON\s*=>\s*q\{hey ho, c'est pas le genre de la maison\}/,
    'fixed response text is source-locked');
like($fullop, qr/\$user->is_authenticated/,
    'privilege exception requires authentication');
like($fullop, qr/\$user->has_level\('Administrator'\)/,
    'global Administrator exception is explicit');
like($fullop, qr/checkUserChannelLevel\(\s*\$self->\{bot\}, \$message, \$channel, \$uid, 75/s,
    'channel exception starts at level 75');
like($fullop, qr/send_message\(\@args\)/,
    'IRC mutations use the existing asynchronous IRC connection');
unlike($fullop, qr/\bsleep\b|system\s*\(|`[^`]+`/,
    'MODE guard contains no blocking shell or sleep path');

like($metrics, qr/mediabot_fullop_corrections_total.*?\['channel', 'mode'\]/s,
    'correction metric is aggregate and bounded');
like($metrics, qr/mediabot_fullop_sanctions_total.*?\['channel'\]/s,
    'sanction metric contains no nickname or hostmask label');

like($fresh, qr/\(32,\s*'Fullop'\)/,
    'fresh schema registers Fullop');
like($migration, qr/INSERT INTO CHANSET_LIST \(chanset\)\s*SELECT 'Fullop'\s*WHERE NOT EXISTS/s,
    'upgrade migration is idempotent');
unlike($migration, qr/INSERT\s+INTO\s+CHANNEL_SET/i,
    'upgrade migration enables no channel');
like($mig_readme, qr/20260903_fullop_chanset\.sql/,
    'authoritative migration order includes Fullop');
like($db_docs, qr/SOURCE .*20260903_fullop_chanset\.sql;/,
    'database operator documentation includes Fullop migration');

like($sample, qr/\[fullop\].*?BAN_SECONDS=600.*?TRUSTED_SERVICE_MASKS=.*?PROTECTED_MODES=/s,
    'public sample documents bounded policy controls without secrets');
like($docs, qr/Raw IRC `KICK` remains allowed/,
    'documentation preserves the ordinary kick exception');
like($docs, qr/Nickname text alone never grants the exception/,
    'documentation records fail-closed identity semantics');
like($docs, qr/`PREFIX` distinguishes member statuses from list modes, especially `q`/,
    'documentation records the cross-network q distinction');

done_testing();
