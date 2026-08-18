# t/cases/841_mb659_enriched_profile.t
# =============================================================================
# mb659 — !profil reuses persisted Achievement progress for a richer card.
# No extra CHANNEL_LOG aggregation is allowed: streak/night/early/comeback
# come from the Achievement registry, and the next goal stays spoiler-safe.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Temp qw(tempdir);

my $DIR = tempdir(CLEANUP => 1);

{
    package Log841;
    sub new { bless {}, shift }
    sub log { 1 }
}

{
    package Ctx841;
    sub new { my ($class, %args) = @_; bless \%args, $class }
    sub bot { $_[0]{bot} }
    sub nick { $_[0]{nick} }
    sub channel { $_[0]{channel} }
    sub args { $_[0]{args} || [] }
}

{
    package Stmt841;
    sub new { my ($class, $row) = @_; bless { row => $row, done => 0 }, $class }
    sub execute { $_[0]{done} = 0; 1 }
    sub fetchrow_hashref {
        my ($self) = @_;
        return if $self->{done}++;
        return { %{ $self->{row} || {} } };
    }
    sub finish { 1 }
}

{
    package DBH841;
    sub new { bless { prepares => [] }, shift }
    sub prepare {
        my ($self, $sql) = @_;
        push @{ $self->{prepares} }, $sql;
        return Stmt841->new({ score => 41 }) if $sql =~ /\bFROM\s+KARMA\b/s;
        return Stmt841->new({ score => 17 }) if $sql =~ /\bFROM\s+TRIVIA_SCORES\b/s;
        die "mb659-841: unexpected direct prepare in !profil: $sql";
    }
}

sub slurp841 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "$path: $!";
    local $/;
    return <$fh>;
}

sub sub_src841 {
    my ($src, $name) = @_;
    my $start = index($src, "sub $name {");
    return undef if $start < 0;
    my $next = index($src, "\nsub ", $start + 5);
    $next = length($src) if $next < 0;
    return substr($src, $start, $next - $start);
}

return sub {
    my ($assert) = @_;

    require Mediabot::Achievements;
    require Mediabot::UserCommands;
    require Mediabot::Helpers;

    my $A = Mediabot::Achievements->new(
        path   => "$DIR/achievements.json",
        logger => Log841->new,
    );

    # A plausible persisted profile. The hidden Phoenix threshold is close
    # (364/365), but it must NEVER become the profile's "Next" spoiler.
    for my $pair (
        [ 'msg_count',            3925 ],
        [ 'karma_score',            41 ],
        [ 'activity_streak_days',   42 ],
        [ 'night_messages',        964 ],
        [ 'morning_messages',      634 ],
        [ 'comeback_days',         364 ],
    ) {
        $A->set_progress($pair->[0], 'balibalo', '#radiocapsule', $pair->[1]);
    }

    for my $id (qw(
        first_msg chatterbox
        night_owl midnight_regular early_bird
        streak_week streak_month
        comeback_week comeback_month comeback_legend
    )) {
        $A->unlock('balibalo', '#radiocapsule', $id);
    }

    my $dbh = DBH841->new;
    my $bot = bless {
        dbh          => $dbh,
        achievements => $A,
        logger       => Log841->new,
    }, 'Mediabot';

    my @out;
    my $gathers = 0;

    no warnings 'redefine';
    local *Mediabot::UserCommands::botPrivmsg =
        sub { push @out, [ 'pub', $_[2] ]; 1 };
    local *Mediabot::UserCommands::botNotice =
        sub { push @out, [ 'not', $_[2] ]; 1 };

    local *Mediabot::Helpers::channel_log_gather = sub {
        my ($self, $dbh_arg, $sql, $bind, $cb, $scope) = @_;
        $gathers++;

        if ($sql =~ /COUNT\(\*\)\s+AS\s+msgs/s) {
            $cb->({
                msgs      => 3925,
                first_ts  => '2026-01-01 00:00:00',
                last_ts   => '2026-08-18 00:00:00',
                days_seen => 229,
            });
        }
        elsif ($sql =~ /cl2\.nick\s+AS\s+nick/s) {
            $cb->({ nick => 'topper', cnt => 5000 });
            $cb->({ nick => 'smaller', cnt => 1000 });
        }
        elsif ($sql =~ /HOUR\(cl\.ts\)\s+AS\s+h/s) {
            $cb->({ h => 2,  c => 964  });
            $cb->({ h => 7,  c => 634  });
            $cb->({ h => 18, c => 2327 });
        }
        else {
            die "mb659-841: unexpected gather SQL: $sql";
        }

        return { live_ok => 1, rows => 1, executed => 1 };
    };

    Mediabot::UserCommands::mbProfil_ctx(
        Ctx841->new(
            bot     => $bot,
            nick    => 'teuk',
            channel => '#radiocapsule',
            args    => [ 'balibalo' ],
        )
    );

    my $text = join "\n", map { $_->[1] } @out;

    # [1] Existing identity/activity card remains intact.
    $assert->like($text, qr/balibalo.*#radiocapsule/s,
        'mb659-841: profile header remains present');
    $assert->like($text, qr/3\.9k msgs \(rank #2, 229d seen\)/,
        'mb659-841: existing activity summary is preserved');
    $assert->like($text, qr/karma .*?\+41.*?trivia 17/s,
        'mb659-841: existing karma/trivia summary is preserved');
    $assert->like($text, qr/peak 18h-19h \(2327 msgs\)/,
        'mb659-841: existing 24h peak remains present');

    # [2] Rich profile line comes solely from persisted Achievement progress.
    $assert->like($text, qr/\x{1F3C6}\s+10\/32/,
        'mb659-841: spoiler-safe visible achievement count is on the progress line');
    $assert->like($text, qr/streak best 42d/,
        'mb659-841: best activity streak is surfaced');
    $assert->like($text, qr/night 964/,
        'mb659-841: Night Owl progress is surfaced');
    $assert->like($text, qr/early 634/,
        'mb659-841: Early Bird progress is surfaced');
    $assert->like($text, qr/comeback 364d/,
        'mb659-841: best observed comeback is surfaced');

    # [3] The closest PUBLIC goal is useful, but mb658 secrets remain secret.
    $assert->like($text,
        qr/\x{1F3AF} Next: .*Creature of the Night.*964\/1k \(96%\)/,
        'mb659-841: profile shows the closest visible achievement goal');
    $assert->unlike($text, qr/Phoenix Rising|Eternal Flame|The Witching Hour/,
        'mb659-841: hidden achievements do not leak through enriched profile');

    # [4] Enrichment does not add another career-history scan or direct SQL.
    $assert->is($gathers, 3,
        'mb659-841: !profil still performs exactly three CHANNEL_LOG gathers');
    $assert->is(scalar @{ $dbh->{prepares} }, 2,
        'mb659-841: !profil still has only the existing karma + trivia prepares');

    # [5] Source-level contract for future regressions.
    my $src = slurp841('Mediabot/UserCommands.pm');
    my $body = sub_src841($src, 'mbProfil_ctx');
    $assert->ok(defined $body, 'mb659-841: mbProfil_ctx source isolated');
    my $gather_sites = () = $body =~ /channel_log_gather\(/g;
    my $prepare_sites = () = $body =~ /\$dbh->prepare\(/g;
    $assert->is($gather_sites, 3,
        'mb659-841: source keeps the three pre-existing gather sites');
    $assert->is($prepare_sites, 2,
        'mb659-841: source keeps the two pre-existing direct prepare sites');
    $assert->like($body, qr/progress_for_nick\(\$target,\s*\$channel\)/,
        'mb659-841: profile reuses persisted Achievement progress');
    $assert->like($body, qr/next_goals\(\$target,\s*\$channel,\s*1\)/,
        'mb659-841: profile reuses spoiler-safe next-goal ordering');
};
