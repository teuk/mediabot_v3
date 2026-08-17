# t/cases/839_mb657_night_owl_ladder.t
# =============================================================================
# mb657 — measurable Night Owl ladder + one optimized hour-band scan.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }

sub slurp839 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "$path: $!";
    local $/;
    return <$fh>;
}

{
    package MB657Harness;
    our @ISA = ('Mediabot::Achievements');

    sub get_for_nick { $_[0]{unlocked} ||= {} }

    sub _worker_identity_sql { return ('1=1') }

    sub _timed_check {
        my ($self, $kind) = @_;
        push @{ $self->{checks} }, $kind;
        return (6000)      if $kind eq 'msg_count';
        return (1000, 50)  if $kind eq 'hour_band';
        return (8)         if $kind eq 'polyphony';
        die "unexpected check $kind";
    }

    sub set_progress {
        my ($self, $kind, $nick, $channel, $value) = @_;
        push @{ $self->{progress_calls} }, [$kind, $nick, $channel, $value];
        return $value;
    }

    sub unlock {
        my ($self, $nick, $channel, $id) = @_;
        $self->{unlocked}{$id} = time();
        push @{ $self->{unlock_calls} }, [$nick, $channel, $id];
        return 1;
    }
}

return sub {
    my ($assert) = @_;

    require Mediabot::Achievements;

    # [1] Three cumulative night milestones share one persistent counter.
    my $defs = Mediabot::Achievements->list_definitions;
    for my $id (qw(night_owl midnight_regular creature_night)) {
        $assert->ok(ref($defs->{$id}) eq 'HASH',
            "mb657-839: catalogue contains $id");
        $assert->is($defs->{$id}{progress_kind}, 'night_messages',
            "mb657-839: $id uses shared night_messages progress");
        $assert->is($defs->{$id}{check_on}, 'msg',
            "mb657-839: $id remains message-derived");
    }
    $assert->is($defs->{night_owl}{threshold}, 50,
        'mb657-839: Night Owl threshold remains 50');
    $assert->is($defs->{midnight_regular}{threshold}, 250,
        'mb657-839: Midnight Regular threshold is 250');
    $assert->is($defs->{creature_night}{threshold}, 1000,
        'mb657-839: Creature of the Night threshold is 1000');
    $assert->is($defs->{early_bird}{progress_kind}, 'morning_messages',
        'mb657-839: existing Early Bird becomes measurable from same scan');

    # [2] check_msg reuses one already-needed hour-band result for progress and
    # cumulative unlocks. No real DB is touched in this harness.
    my $h = bless {
        bot            => { dbh => bless({}, 'MB657DummyDBH') },
        checks         => [],
        progress_calls => [],
        unlock_calls   => [],
        unlocked       => {},
    }, 'MB657Harness';

    $h->check_msg('Teuk', '#test');

    my %progress = map { $_->[0] => $_->[3] } @{ $h->{progress_calls} };
    $assert->is($progress{night_messages}, 1000,
        'mb657-839: exact night count is persisted as progress');
    $assert->is($progress{morning_messages}, 50,
        'mb657-839: exact morning count is persisted from same result');

    my %unlock = map { $_->[2] => 1 } @{ $h->{unlock_calls} };
    $assert->ok($unlock{night_owl},
        'mb657-839: 1000 night messages includes Night Owl');
    $assert->ok($unlock{midnight_regular},
        'mb657-839: 1000 night messages includes Midnight Regular');
    $assert->ok($unlock{creature_night},
        'mb657-839: 1000 night messages unlocks Creature of the Night');
    $assert->ok($unlock{early_bird},
        'mb657-839: same scan can still unlock Early Bird');

    my $hour_checks = grep { $_ eq 'hour_band' } @{ $h->{checks} };
    $assert->is($hour_checks, 1,
        'mb657-839: one hour-band calculation feeds all four achievements');

    # [3] Source contract: no GROUP BY HOUR temporary/filesort path and the
    # async parent imports both progress kinds calculated in the child.
    my $src = slurp839('Mediabot/Achievements.pm');
    my ($check_msg) = $src =~ /(sub check_msg \{.*?\n\})\n\n# -- Hook/s;
    $assert->ok(defined($check_msg),
        'mb657-839: check_msg body is discoverable');
    if (defined $check_msg) {
        $assert->unlike($check_msg, qr/GROUP BY HOUR\(cl\.ts\)/,
            'mb657-839: old GROUP BY HOUR scan is gone');
        $assert->like($check_msg,
            qr/COALESCE\(SUM\(CASE\s+WHEN HOUR\(cl\.ts\) BETWEEN 0 AND 5/s,
            'mb657-839: night count uses conditional aggregate');
        $assert->like($check_msg,
            qr/COALESCE\(SUM\(CASE\s+WHEN HOUR\(cl\.ts\) BETWEEN 6 AND 8/s,
            'mb657-839: morning count uses conditional aggregate');
        my $hour_selects = () = $check_msg =~ /AS\s+(?:night_count|morning_count)/g;
        $assert->is($hour_selects, 2,
            'mb657-839: one query exposes exactly the two hour-band aggregates');
        $assert->like($check_msg, qr/->set_progress\('night_messages'/,
            'mb657-839: night result feeds generic progress');
        $assert->like($check_msg, qr/->set_progress\('morning_messages'/,
            'mb657-839: morning result feeds generic progress');
    }

    $assert->like($src,
        qr/qw\(msg_count channels_active night_messages morning_messages\)/,
        'mb657-839: async parent imports both new worker progress values');

    # [4] The scan gate uses configurable thresholds, not a stale hard-coded
    # n >= 50 condition.
    if (defined $check_msg) {
        $assert->like($check_msg, qr/\@hour_pending/,
            'mb657-839: only locked hour-band goals drive future scans');
        $assert->like($check_msg, qr/\$n\s*>=\s*\$hour_floor/,
            'mb657-839: scan floor follows the next reachable threshold');
        $assert->unlike($check_msg, qr/if\s*\(\s*\$n\s*>=\s*50\s*&&/,
            'mb657-839: old hard-coded 50-message gate is gone');
    }
};
