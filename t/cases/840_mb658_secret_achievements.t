# t/cases/840_mb658_secret_achievements.t
# =============================================================================
# mb658 — secret achievements: invisible while locked, ordinary once revealed.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Temp qw(tempdir);

my $DIR = tempdir(CLEANUP => 1);

{
    package Log840;
    sub new { bless {}, shift }
    sub log { 1 }
}

{
    package Ctx840;
    sub new { my ($class, %args) = @_; bless \%args, $class }
    sub bot { $_[0]{bot} }
    sub nick { $_[0]{nick} }
    sub channel { $_[0]{channel} }
    sub args { $_[0]{args} || [] }
}

{
    package MB658NightHarness;
    our @ISA = ('Mediabot::Achievements');

    sub get_for_nick { $_[0]{unlocked} ||= {} }
    sub _worker_identity_sql { return ('1=1') }

    sub _timed_check {
        my ($self, $kind) = @_;
        push @{ $self->{checks} }, $kind;
        return (6000)      if $kind eq 'msg_count';
        return (5000, 50)  if $kind eq 'hour_band';
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

sub slurp840 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "$path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    require Mediabot::Achievements;
    require Mediabot::UserCommands;
    require Mediabot::Helpers;

    my $defs = Mediabot::Achievements->list_definitions;

    # [1] Three legendary secrets extend counters that already exist. They do
    # not introduce a new persistence kind or a new source of historical truth.
    my %expect = (
        witching_hour => [ 'night_messages',       5000, 'The Witching Hour' ],
        eternal_flame => [ 'activity_streak_days',  365, 'Eternal Flame' ],
        phoenix_rising => [ 'comeback_days',          365, 'Phoenix Rising' ],
    );

    for my $id (sort keys %expect) {
        my ($kind, $threshold, $name) = @{ $expect{$id} };
        $assert->ok(ref($defs->{$id}) eq 'HASH',
            "mb658-840: catalogue contains secret $id");
        $assert->ok($defs->{$id}{hidden},
            "mb658-840: $id is marked hidden");
        $assert->is($defs->{$id}{rarity}, 'legendary',
            "mb658-840: $id is legendary");
        $assert->is($defs->{$id}{progress_kind}, $kind,
            "mb658-840: $id reuses $kind");
        $assert->is($defs->{$id}{threshold}, $threshold,
            "mb658-840: $id threshold");
        $assert->is($defs->{$id}{name}, $name,
            "mb658-840: $id reveal name");
    }

    my @hidden = sort grep { $defs->{$_}{hidden} } keys %$defs;
    $assert->is(join(',', @hidden),
        'eternal_flame,phoenix_rising,witching_hour',
        'mb658-840: exactly the three MB658 secrets are hidden');

    # [2] Snapshot may carry hidden metadata internally, but next_goals must
    # never turn a locked secret into a spoiler.
    my $A = Mediabot::Achievements->new(
        path => "$DIR/a.json",
        logger => Log840->new,
    );
    $A->set_progress('night_messages', 'teuk', '#c', 4999);
    $A->set_progress('activity_streak_days', 'teuk', '#c', 364);
    $A->set_progress('comeback_days', 'teuk', '#c', 364);

    my $snap = $A->progress_snapshot('teuk', '#c');
    for my $id (keys %expect) {
        $assert->ok($snap->{$id}{hidden},
            "mb658-840: snapshot tags $id as hidden");
        $assert->ok(!$snap->{$id}{unlocked},
            "mb658-840: $id starts locked");
    }

    my $goals = $A->next_goals('teuk', '#c', 100);
    my %goal_id = map { $_->{id} => 1 } @$goals;
    for my $id (keys %expect) {
        $assert->ok(!$goal_id{$id},
            "mb658-840: next_goals does not spoil $id");
    }

    # [3] Real UserCommands rendering: catalogue/progress/default views conceal
    # every locked secret. Unlocking one reveals it as an ordinary achievement.
    my @out;
    no warnings 'redefine';
    local *Mediabot::UserCommands::botPrivmsg =
        sub { push @out, [ 'pub', $_[2] ]; 1 };
    local *Mediabot::UserCommands::botNotice =
        sub { push @out, [ 'not', $_[2] ]; 1 };
    local *Mediabot::Helpers::getIdChansetList = sub { undef };

    my $bot = bless {
        achievements => $A,
        logger       => Log840->new,
    }, 'Mediabot';

    @out = ();
    Mediabot::UserCommands::mbAchievements_ctx(
        Ctx840->new(
            bot => $bot, nick => 'teuk', channel => '#c',
            args => [ 'list' ],
        )
    );
    my $text = join "\n", map { $_->[1] } @out;
    for my $id (keys %expect) {
        $assert->unlike($text, qr/\Q$expect{$id}[2]\E/,
            "mb658-840: catalogue does not reveal $id");
    }
    $assert->like($text, qr/Secret achievements are revealed only when unlocked/,
        'mb658-840: catalogue explains the secret contract without spoilers');
    $assert->like($text, qr/Total:\s+32 visible achievements available/,
        'mb658-840: catalogue denominator excludes all locked secrets');

    @out = ();
    Mediabot::UserCommands::mbAchievements_ctx(
        Ctx840->new(
            bot => $bot, nick => 'teuk', channel => '#c',
            args => [ 'progress' ],
        )
    );
    $text = join "\n", map { $_->[1] } @out;
    for my $id (keys %expect) {
        $assert->unlike($text, qr/\Q$expect{$id}[2]\E/,
            "mb658-840: progress view does not reveal $id");
    }

    @out = ();
    Mediabot::UserCommands::mbAchievements_ctx(
        Ctx840->new(
            bot => $bot, nick => 'teuk', channel => '#c',
            args => [],
        )
    );
    $text = join "\n", map { $_->[1] } @out;
    for my $id (keys %expect) {
        $assert->unlike($text, qr/\Q$expect{$id}[2]\E/,
            "mb658-840: closest-goal/default view does not reveal $id");
    }

    $assert->ok($A->unlock('teuk', '#c', 'witching_hour'),
        'mb658-840: a secret can be unlocked normally');

    @out = ();
    Mediabot::UserCommands::mbAchievements_ctx(
        Ctx840->new(
            bot => $bot, nick => 'teuk', channel => '#c',
            args => [],
        )
    );
    $text = join "\n", map { $_->[1] } @out;
    $assert->like($text, qr/The Witching Hour/,
        'mb658-840: unlocked secret is revealed in the normal achievement view');
    $assert->like($text, qr/1\s+\/\s+33 visible achievements/,
        'mb658-840: revealed secret joins the visible denominator');

    # [4] Existing check paths unlock the secret rungs from the same counters.
    # Streak/comeback add no query at all; Night uses exactly the already-shared
    # MB657 hour-band result.
    my $S = Mediabot::Achievements->new(
        path => "$DIR/streak.json",
        logger => Log840->new,
    );
    $S->check_streak('teuk', '#c', 365, 365);
    $assert->ok(exists $S->get_for_nick('teuk', '#c')->{eternal_flame},
        'mb658-840: 365-day best streak reveals Eternal Flame');

    my $C = Mediabot::Achievements->new(
        path => "$DIR/comeback.json",
        logger => Log840->new,
    );
    $C->check_comeback('teuk', '#c', 365 * 86400);
    $assert->ok(exists $C->get_for_nick('teuk', '#c')->{phoenix_rising},
        'mb658-840: 365-day comeback reveals Phoenix Rising');

    my $N = bless {
        bot            => { dbh => bless({}, 'MB658DummyDBH') },
        checks         => [],
        progress_calls => [],
        unlock_calls   => [],
        unlocked       => {},
    }, 'MB658NightHarness';

    $N->check_msg('Teuk', '#test');
    my %night_unlock = map { $_->[2] => 1 } @{ $N->{unlock_calls} };
    $assert->ok($night_unlock{witching_hour},
        'mb658-840: 5000 night messages reveal The Witching Hour');
    my $hour_checks = grep { $_ eq 'hour_band' } @{ $N->{checks} };
    $assert->is($hour_checks, 1,
        'mb658-840: secret night rung adds no second hour-band calculation');

    # [5] Source contracts: hidden filtering is applied not only to
    # !achievements but also to !profil, so the latter cannot disclose the
    # existence of locked secrets through its X/Y denominator.
    my $src_a = slurp840('Mediabot/Achievements.pm');
    my $src_u = slurp840('Mediabot/UserCommands.pm');

    $assert->like($src_a,
        qr/qw\(night_owl midnight_regular creature_night witching_hour early_bird\)/,
        'mb658-840: secret night rung participates in existing scan gate');
    $assert->like($src_a,
        qr/qw\(streak_week streak_month streak_master eternal_flame\)/,
        'mb658-840: secret streak rung reuses check_streak');
    $assert->like($src_a,
        qr/qw\(comeback_week comeback_month comeback_legend phoenix_rising\)/,
        'mb658-840: secret comeback rung reuses check_comeback');
    $assert->like($src_u,
        qr/!\$defs->\{\$_\}\{hidden\}\s*\|\|\s*exists \$unl->\{\$_\}/,
        'mb658-840: !profil denominator reveals secrets only after unlock');
};
