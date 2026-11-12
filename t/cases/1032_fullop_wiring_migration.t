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
like($commands, qr/add_ban\(.*?send_message\("MODE".*?authorize_delegated_ban\(/s,
    'service delegation is armed only after storage and the primary IRC ban');

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
like($metrics, qr/mediabot_fullop_delegated_bans_total.*?\['channel'\]/s,
    'delegated-ban metric remains aggregate and bounded');

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

like($sample, qr/\[fullop\].*?BAN_SECONDS=600.*?TRUSTED_SERVICE_MASKS=.*?DELEGATED_BAN_SERVICES=.*?PROTECTED_MODES=/s,
    'public sample documents bounded policy controls without secrets');
like($docs, qr/Raw IRC `KICK` remains allowed/,
    'documentation preserves the ordinary kick exception');
like($docs, qr/Nickname text alone never grants the exception/,
    'documentation records fail-closed identity semantics');
like($docs, qr/`PREFIX` distinguishes member statuses from list modes, especially `q`/,
    'documentation records the cross-network q distinction');
like($docs, qr/lasts five seconds.*?same channel and literal target host.*?first matching service `\+b`/s,
    'documentation fixes the one-shot causal service boundary');

like($main, qr/sub _build_irc \{\s*my \(\$loop\) = \@_;.*?\$mediabot->\{fullop\}->reset_connection\(\) if \$mediabot->\{fullop\};.*?Net::Async::IRC->new/s,
    'fresh transport construction resets Fullop before new IRC registration');
is(scalar(() = $main =~ /_build_irc\(\$loop\)/g), 3,
    'shared builder is documented and used for initial connection and reconnect');


# MB1260: replay the two unchanged handler bodies in a bounded harness.
# This is not a full Net::Async::IRC integration test.
{
    package MB1260::Bot;
    sub sethChannelsNicksOnChan {my($s,$c,@n)=@_;$s->{hChannelsNicks}{$c}=\@n}
    sub sethChannelsNicksEndOnChan {$_[0]{hChannelsNicksEnd}{$_[1]}=$_[2]}
    package MB1260::Log;
    sub log {$_[0]{calls}++}
    package MB1260::Metrics;
    sub set {push @{$_[0]{calls}}, [@_[1..$#_]]}
    package MB1260::Fullop;
    sub names_from_blob {my $s=shift;$s->{parses}++;my $b=shift;$b=~s/[@+]//g;split /\s+/,$b}
    sub sweep_channel {push @{$_[0]{sweeps}},[@_[1..$#_]]}
}
my $handlers='';
for my $name (qw(on_message_RPL_NAMEREPLY on_message_RPL_ENDOFNAMES)) {
    my ($body)=$main=~ /(^sub \Q$name\E \{.*?^\})/ms;
    die "missing $name" unless $body;
    $handlers.=$body."\n";
}
my $factory=eval q{
    package MB1260::Replay;
    use Scalar::Util ();
    our $mediabot;
    sub log_debug_args { $mediabot->{debug_calls}++ }
    sub _irc_message_args { @{$_[0]} }
}.$handlers.q{
    sub { $mediabot=$_[0]; return (\&on_message_RPL_NAMEREPLY,\&on_message_RPL_ENDOFNAMES) }
};
die $@ unless $factory;
my $old=bless {},'MB1260::IRC';
my $current_transport=bless {},'MB1260::IRC';
my $bot=bless {irc=>$current_transport,logger=>bless({},'MB1260::Log'),
    metrics=>bless({},'MB1260::Metrics'),fullop=>bless({},'MB1260::Fullop'),
    hChannelsNicks=>{'#test'=>['Published']},
    hChannelsNicksTmp=>{'#test'=>['Fresh']},hChannelsNicksEnd=>{'#test'=>0}},'MB1260::Bot';
my($chunk,$end)=$factory->($bot);
$chunk->($old,['bot','=',' #unused','@Departed'],{target_name=>'#test'});
is_deeply($bot->{hChannelsNicksTmp}{'#test'},['Fresh'],'old 353 cannot contaminate current partial snapshot');
$end->($old,['bot','#test'],{});
is_deeply($bot->{hChannelsNicks}, {'#test'=>['Published']},'old 366 cannot publish or replace current membership');
is_deeply($bot->{hChannelsNicksTmp}, {'#test'=>['Fresh']},'old 366 cannot consume current buffer');
is($bot->{hChannelsNicksEnd}{'#test'},0,'old 366 cannot mark synchronization complete');
ok(!$bot->{fullop}{parses} && !$bot->{fullop}{sweeps},'old events perform no Fullop normalization or sweep');
ok(!$bot->{debug_calls} && !$bot->{logger}{calls} && !$bot->{metrics}{calls},'old events have no log or metric side effects');
# Reset fixture so accepted-path checks remain independent of the baseline failure.
$bot->{hChannelsNicksTmp}={'#test'=>['Fresh']};
$bot->{fullop}{sweeps}=[];
$chunk->($current_transport,['bot','=','#test','@Alice +Bob Alice'],{target_name=>'#test'});
is_deeply($bot->{hChannelsNicksTmp}{'#test'},[qw(Fresh Alice Bob Alice)],'current 353 preserves prefix normalization and accumulation');
$end->($current_transport,['bot','#test'],{});
is_deeply($bot->{hChannelsNicks}{'#test'},[qw(Fresh Alice Bob)],'current 366 preserves order and deduplication');
ok(!exists $bot->{hChannelsNicksTmp}{'#test'} && $bot->{hChannelsNicksEnd}{'#test'}==1,'current completion consumes buffer and marks ready');
is_deeply($bot->{fullop}{sweeps},[['#test',qw(Fresh Alice Bob)]],'current completion performs exactly one sweep');
is($bot->{metrics}{calls}[-1][1],3,'current completion retains member count metric');
$bot->{irc}=undef;
$bot->{hChannelsNicksTmp}={'#test'=>['Detached']};
$chunk->($current_transport,['bot','=','#test','Late'],{target_name=>'#test'});
$end->($current_transport,['bot','#test'],{});
ok(eval {$chunk->(undef,undef,undef);$end->(undef,undef,undef);1}, 'absent transport is rejected before payload access');
is_deeply($bot->{hChannelsNicksTmp},{'#test'=>['Detached']},'detached or absent source cannot mutate buffers, even with malformed payload');
is(scalar @{$bot->{fullop}{sweeps}},1,'detached callbacks cannot trigger another sweep');

done_testing();
