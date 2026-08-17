# t/cases/837_mb655_activity_streak_achievements.t
# =============================================================================
# mb655 — activity streak achievements reuse !streak's existing career scan.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }

sub slurp837 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "$path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    require Mediabot::Achievements;

    # [1] The catalogue exposes three measurable milestones on one shared
    # monotonic best-streak counter.
    my $defs = Mediabot::Achievements->list_definitions;
    for my $id (qw(streak_week streak_month streak_master)) {
        $assert->ok(ref($defs->{$id}) eq 'HASH',
            "mb655-837: catalogue contains $id");
        $assert->is($defs->{$id}{progress_kind}, 'activity_streak_days',
            "mb655-837: $id uses shared streak progress counter");
        $assert->is($defs->{$id}{check_on}, 'activity',
            "mb655-837: $id is classified as an activity achievement");
    }
    $assert->is($defs->{streak_week}{threshold}, 7,
        'mb655-837: On a Roll default threshold is 7 days');
    $assert->is($defs->{streak_month}{threshold}, 30,
        'mb655-837: Habit Formed default threshold is 30 days');
    $assert->is($defs->{streak_master}{threshold}, 100,
        'mb655-837: Streak Master default threshold is 100 days');

    # [2] Exercise check_streak without touching storage.  This verifies that
    # best-ever, not merely current streak, drives progress and unlocks.
    {
        package MB655StreakHarness;
        our @ISA = ('Mediabot::Achievements');
        sub set_progress {
            my ($self, $kind, $nick, $channel, $value) = @_;
            push @{ $self->{progress_calls} }, [$kind, $nick, $channel, $value];
            return $value;
        }
        sub unlock {
            my ($self, $nick, $channel, $id) = @_;
            push @{ $self->{unlock_calls} }, [$nick, $channel, $id];
            return 1;
        }
    }

    my $h = bless { progress_calls => [], unlock_calls => [] }, 'MB655StreakHarness';
    my $saved = $h->check_streak('Teuk', '#test', 3, 30);
    $assert->is($saved, 30,
        'mb655-837: check_streak returns persisted best-ever progress');
    $assert->is(join('|', @{ $h->{progress_calls}[0] }),
        'activity_streak_days|Teuk|#test|30',
        'mb655-837: best-ever streak is persisted on shared progress kind');
    $assert->is(join('|', map { $_->[2] } @{ $h->{unlock_calls} }),
        'streak_week|streak_month',
        'mb655-837: 30-day best unlocks week and month but not master');

    $h->{progress_calls} = [];
    $h->{unlock_calls} = [];
    $h->check_streak('Teuk', '#test', 1, 100);
    $assert->is(join('|', map { $_->[2] } @{ $h->{unlock_calls} }),
        'streak_week|streak_month|streak_master',
        'mb655-837: 100-day best unlocks every streak milestone');

    $h->{progress_calls} = [];
    $h->{unlock_calls} = [];
    my $bad = $h->check_streak('Teuk', '#test', 'oops', 'oops');
    $assert->is($bad, 0,
        'mb655-837: invalid streak values fail closed');
    $assert->is(scalar(@{ $h->{progress_calls} }), 0,
        'mb655-837: invalid streak does not persist progress');
    $assert->is(scalar(@{ $h->{unlock_calls} }), 0,
        'mb655-837: invalid streak does not unlock anything');

    # [3] !streak must reuse its existing $best result; no second history query
    # is added just to feed Achievements.  Third-party inspection remains
    # read-only by guarding the hook to the invoking nick.
    my $uc = slurp837('Mediabot/UserCommands.pm');
    my ($streak_body) = $uc =~ /(sub mbStreak_ctx \{.*?\n\})\n\n# -+/s;
    $assert->ok(defined($streak_body),
        'mb655-837: mbStreak_ctx body is discoverable');
    if (defined $streak_body) {
        $assert->like($streak_body,
            qr/lc\(\$target\)\s+eq\s+lc\(\$nick\)/,
            'mb655-837: only self streak inspection may update achievements');
        $assert->like($streak_body,
            qr/->check_streak\(\$nick,\s*\$channel,\s*\$streak,\s*\$best\)/,
            'mb655-837: existing current/best streak result feeds Achievements');
        my $distinct_day_queries = () = $streak_body =~ /SELECT\s+DISTINCT\s+DATE\(ts\)/ig;
        $assert->is($distinct_day_queries, 1,
            'mb655-837: achievement hook adds no second streak history scan');
    }

    # [4] The feature is schema-neutral: it uses the generic progress/unlock
    # storage already introduced by mb646.
    my $ach_src = slurp837('Mediabot/Achievements.pm');
    my ($check_body) = $ach_src =~ /(sub check_streak \{.*?\n\})\n\n# -- Hook/s;
    $assert->ok(defined($check_body),
        'mb655-837: check_streak method body is discoverable');
    if (defined $check_body) {
        $assert->like($check_body, qr/->set_progress\('activity_streak_days'/,
            'mb655-837: check_streak reuses generic progress persistence');
        $assert->unlike($check_body, qr/\b(?:INSERT|UPDATE|DELETE|ALTER|CREATE|DROP)\b/i,
            'mb655-837: check_streak contains no direct schema or SQL mutation');
    }
};
