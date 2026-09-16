# t/cases/1061_mb738_achievement_timezone_accuracy.t
# =============================================================================
# mb738 — channel civil time and full achievement accuracy pass.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Temp qw(tempdir);
use Time::Local qw(timegm);

sub slurp1051 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

{
    package Log1051;
    sub new { bless { lines => [] }, shift }
    sub log { push @{ $_[0]{lines} }, [ @_[1 .. $#_] ]; 1 }
}

return sub {
    my ($assert) = @_;

    require Mediabot::Achievements;
    my $dir = tempdir(CLEANUP => 1);
    my $ach = Mediabot::Achievements->new(
        path => "$dir/achievements.json", logger => Log1051->new,
    );

    # IANA conversion must honour both winter and summer offsets.
    my $winter = timegm(0, 30, 7, 15, 0, 126);  # 2026-01-15 07:30 UTC
    my $summer = timegm(0, 30, 6, 15, 6, 126);  # 2026-07-15 06:30 UTC
    $assert->is($ach->_channel_local_hour('Europe/Paris', $winter), 8,
        'mb738-1051: Europe/Paris winter civil hour is DST-aware');
    $assert->is($ach->_channel_local_hour('Europe/Paris', $summer), 8,
        'mb738-1051: Europe/Paris summer civil hour is DST-aware');
    $assert->ok(Mediabot::Achievements::_valid_channel_timezone('America/Montreal'),
        'mb738-1051: a real IANA channel timezone is accepted');
    $assert->ok(!Mediabot::Achievements::_valid_channel_timezone('../Paris'),
        'mb738-1051: path-like or invalid timezone input is rejected');

    # Changing policy invalidates only timezone-derived state.
    $ach->unlock('alice', '#room', 'night_owl');
    $ach->unlock('alice', '#room', 'first_msg');
    $ach->set_progress('night_messages', 'alice', '#room', 75);
    $ach->set_progress('morning_messages', 'alice', '#room', 12);
    $ach->set_progress('msg_count', 'alice', '#room', 900);
    my $reset = $ach->reset_channel_hourbands('#room', 1);
    my $left = $ach->get_for_nick('alice', '#room');
    $assert->is($reset->{unlocks}, 1,
        'mb738-1051: hour-band reconciliation reports removed unlocks');
    $assert->ok(!exists($left->{night_owl}) && exists($left->{first_msg}),
        'mb738-1051: reconciliation preserves unrelated unlocks');
    $assert->is($ach->progress('night_messages', 'alice', '#room'), 0,
        'mb738-1051: stale night progress is cleared');
    $assert->is($ach->progress('msg_count', 'alice', '#room'), 900,
        'mb738-1051: unrelated message progress is preserved');

    # Every measured hook owns the value it receives; instant events stay
    # explicit. The sniper boundary is exact rather than integer-rounded.
    $ach->check_trivia('bob', '#room', 10, 2.001);
    $assert->is($ach->progress('trivia_correct', 'bob', '#room'), 10,
        'mb738-1051: trivia hook persists its authoritative total');
    $assert->ok(!exists($ach->get_for_nick('bob', '#room')->{trivia_sniper}),
        'mb738-1051: 2.001 seconds does not earn the 2-second sniper');
    $ach->check_trivia('bob', '#room', 11, 2.000);
    $assert->ok(exists($ach->get_for_nick('bob', '#room')->{trivia_sniper}),
        'mb738-1051: the advertised inclusive 2.000-second boundary earns sniper');

    my $defs = Mediabot::Achievements::list_definitions();
    $assert->like($defs->{night_owl}{desc}, qr/00:00.*05:59 channel time/,
        'mb738-1051: Night Owl states its precise channel-local band');
    $assert->like($defs->{early_bird}{desc}, qr/06:00.*08:59 channel time/,
        'mb738-1051: Early Bird states its precise channel-local band');
    $assert->like($defs->{gift_giver}{desc}, qr/on a channel/,
        'mb738-1051: Gift Giver scope is explicit');

    my $schema = slurp1051('install/mediabot.sql');
    my $migration = slurp1051('install/migrations/20260916_channel_timezone.sql');
    my $channel = slurp1051('Mediabot/Channel.pm');
    my $commands = slurp1051('Mediabot/ChannelCommands.pm');
    my $runtime = slurp1051('Mediabot/Mediabot.pm');
    my $db = slurp1051('Mediabot/DB.pm');
    my $user = slurp1051('Mediabot/UserCommands.pm');
    my $karma = slurp1051('Mediabot/Karma.pm');
    my $source = slurp1051('Mediabot/Achievements.pm');
    my $docs = slurp1051('docs/ACHIEVEMENTS.md');

    $assert->like($schema,
        qr/`timezone`\s+VARCHAR\(64\).*?NOT NULL DEFAULT 'UTC'/s,
        'mb738-1051: fresh schema stores an explicit channel timezone');
    $assert->like($migration,
        qr/ADD COLUMN IF NOT EXISTS `timezone`.*?DEFAULT 'UTC'/s,
        'mb738-1051: existing databases receive the replay-safe column');
    $assert->like($channel, qr/sub get_timezone\b.*?sub set_timezone\b/s,
        'mb738-1051: Channel object owns timezone reads and writes');
    $assert->like($runtime,
        qr/SELECT id_channel, name, description, topic, tmdb_lang, timezone,/,
        'mb738-1051: startup hydrates timezone into channel objects');
    $assert->like($commands,
        qr/chanset \[#channel\] timezone <Area\/City>/,
        'mb738-1051: chanset help exposes channel timezone syntax');
    $assert->like($commands,
        qr/_valid_iana_timezone\(\$timezone\).*?CONVERT_TZ.*?set_timezone\(\$timezone\).*?reset_channel_hourbands/s,
        'mb738-1051: timezone changes validate, probe and reconcile in order');
    $assert->like($db, qr/SET time_zone = '\+00:00'/,
        'mb738-1051: application database sessions are pinned to UTC');

    $assert->like($source,
        qr/HOUR\(CONVERT_TZ\(cl\.ts, \\\@\\\@session\.time_zone, \?\)\).*?BETWEEN 0 AND 5/s,
        'mb738-1051: Night Owl history uses explicit named-zone conversion');
    $assert->like($source,
        qr/my \@hour_candidates.*?local_hour.*?night_owl.*?early_bird/s,
        'mb738-1051: only the triggering message local band is eligible');
    $assert->like($user,
        qr/sub mbStreak_ctx\b.*?my \$channel_timezone = eval.*?my \$sql_timezone = .*?DATE\(CONVERT_TZ\(cl\.ts, \@\@session\.time_zone, \?\)\) AS day/s,
        'mb738-1051: activity streak declares and uses its channel-local calendar');
    $assert->like($user,
        qr/started\s*=>\s*Time::HiRes::time\(\).*?my \$response_time = Time::HiRes::time\(\)/s,
        'mb738-1051: Trivia Sniper uses high-resolution elapsed time end to end');
    $assert->like($karma,
        qr/bump_progress\(\s*'karma_given'/s,
        'mb738-1051: Gift Giver increments durable progress across restarts');
    $assert->like($docs, qr/A daytime message cannot announce Night Owl/,
        'mb738-1051: operator documentation records the contextual unlock rule');
};
