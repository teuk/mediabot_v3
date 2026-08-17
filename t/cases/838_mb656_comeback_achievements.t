# t/cases/838_mb656_comeback_achievements.t
# =============================================================================
# mb656 — comeback achievements from pre-JOIN USER_SEEN evidence.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }

sub slurp838 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "$path: $!";
    local $/;
    return <$fh>;
}

{
    package MB656STH;
    sub new {
        my ($class, $row, $owner) = @_;
        return bless { row => $row, owner => $owner }, $class;
    }
    sub execute {
        my ($self, @bind) = @_;
        $self->{owner}{execute_count}++;
        $self->{owner}{last_bind} = [@bind];
        return 1;
    }
    sub fetchrow_hashref { $_[0]{row} }
    sub finish { 1 }
}

{
    package MB656DBH;
    sub new {
        my ($class, $row) = @_;
        return bless {
            row => $row,
            prepare_count => 0,
            execute_count => 0,
            sql => [],
        }, $class;
    }
    sub prepare {
        my ($self, $sql) = @_;
        $self->{prepare_count}++;
        push @{ $self->{sql} }, $sql;
        return MB656STH->new($self->{row}, $self);
    }
}

{
    package MB656Harness;
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

{
    package MB656ConsumeHarness;
    our @ISA = ('Mediabot::Achievements');
    sub check_comeback {
        my ($self, @args) = @_;
        push @{ $self->{checks} }, [@args];
        return 77;
    }
}

return sub {
    my ($assert) = @_;

    require Mediabot::Achievements;

    # [1] Catalogue: three measurable comeback milestones share one counter.
    my $defs = Mediabot::Achievements->list_definitions;
    for my $id (qw(comeback_week comeback_month comeback_legend)) {
        $assert->ok(ref($defs->{$id}) eq 'HASH',
            "mb656-838: catalogue contains $id");
        $assert->is($defs->{$id}{progress_kind}, 'comeback_days',
            "mb656-838: $id uses shared comeback progress");
        $assert->is($defs->{$id}{check_on}, 'comeback',
            "mb656-838: $id is classified as comeback");
    }
    $assert->is($defs->{comeback_week}{threshold}, 7,
        'mb656-838: Welcome Back threshold is 7 days');
    $assert->is($defs->{comeback_month}{threshold}, 30,
        'mb656-838: Long Time No See threshold is 30 days');
    $assert->is($defs->{comeback_legend}{threshold}, 90,
        'mb656-838: The Return threshold is 90 days');

    # [2] check_comeback records the longest observed absence and unlocks the
    # cumulative ladder without doing its own SQL.
    my $h = bless {
        progress_calls => [],
        unlock_calls   => [],
    }, 'MB656Harness';

    my $saved = $h->check_comeback('Teuk', '#test', 30 * 86400 + 123);
    $assert->is($saved, 30,
        'mb656-838: 30-day absence is recorded as whole days');
    $assert->is(join('|', @{ $h->{progress_calls}[0] }),
        'comeback_days|Teuk|#test|30',
        'mb656-838: comeback_days receives the observed absence');
    $assert->is(join('|', map { $_->[2] } @{ $h->{unlock_calls} }),
        'comeback_week|comeback_month',
        'mb656-838: 30 days unlocks week and month only');

    $h->{progress_calls} = [];
    $h->{unlock_calls} = [];
    $h->check_comeback('Teuk', '#test', 90 * 86400);
    $assert->is(join('|', map { $_->[2] } @{ $h->{unlock_calls} }),
        'comeback_week|comeback_month|comeback_legend',
        'mb656-838: 90 days unlocks the complete ladder');

    $h->{progress_calls} = [];
    $h->{unlock_calls} = [];
    $assert->is($h->check_comeback('Teuk', '#test', 'oops'), 0,
        'mb656-838: invalid absence fails closed');
    $assert->is(scalar(@{ $h->{progress_calls} }), 0,
        'mb656-838: invalid absence writes no progress');
    $assert->is(scalar(@{ $h->{unlock_calls} }), 0,
        'mb656-838: invalid absence unlocks nothing');

    # [3] JOIN-time capture is SELECT-only, lowercases the lookup key and
    # accepts a compatible hostmask.
    my $dbh = MB656DBH->new({
        userhost     => '~teuk@cloak.example',
        event_type   => 'quit',
        seen_at      => '2026-07-01 12:00:00',
        away_seconds => 31 * 86400,
    });
    my $capture = bless {
        bot => { dbh => $dbh },
        _comeback_pending => {},
    }, 'Mediabot::Achievements';

    $assert->is(
        $capture->note_comeback_candidate('TeuK', 'teuk@cloak.example'),
        1,
        'mb656-838: compatible 31-day USER_SEEN row becomes a candidate'
    );
    $assert->is($dbh->{prepare_count}, 1,
        'mb656-838: one read is enough to sample USER_SEEN');
    $assert->is($dbh->{last_bind}[0], 'teuk',
        'mb656-838: USER_SEEN lookup uses normalized nick');
    $assert->like($dbh->{sql}[0], qr/\bSELECT\b.*\bUSER_SEEN\b/s,
        'mb656-838: capture reads USER_SEEN');
    $assert->unlike($dbh->{sql}[0],
        qr/\b(?:INSERT|UPDATE|DELETE|REPLACE|ALTER|CREATE|DROP)\b/i,
        'mb656-838: JOIN-time capture SQL is read-only');
    $assert->is($capture->{_comeback_pending}{teuk}{away_seconds}, 31 * 86400,
        'mb656-838: pre-JOIN age is preserved in memory');

    # [4] Multiple shared-channel JOINs must keep the FIRST long-absence
    # candidate instead of replacing it after USER_SEEN has been refreshed.
    my $prepares_before = $dbh->{prepare_count};
    $dbh->{row}{away_seconds} = 1;
    $assert->is(
        $capture->note_comeback_candidate('Teuk', 'teuk@cloak.example'),
        1,
        'mb656-838: existing fresh candidate survives another channel JOIN'
    );
    $assert->is($dbh->{prepare_count}, $prepares_before,
        'mb656-838: second JOIN does not reread already-refreshed USER_SEEN');
    $assert->is($capture->{_comeback_pending}{teuk}{away_seconds}, 31 * 86400,
        'mb656-838: original long absence is not overwritten');

    # [5] A recycled nick on a clearly different ident+host is rejected.
    my $dbh_bad = MB656DBH->new({
        userhost     => 'oldident@old.example',
        event_type   => 'quit',
        seen_at      => '2026-07-01 12:00:00',
        away_seconds => 31 * 86400,
    });
    my $bad = bless {
        bot => { dbh => $dbh_bad },
        _comeback_pending => {},
    }, 'Mediabot::Achievements';
    $assert->is(
        $bad->note_comeback_candidate('Teuk', 'newident@new.example'),
        0,
        'mb656-838: incompatible old/current hostmask rejects nick reuse'
    );
    $assert->ok(!exists $bad->{_comeback_pending}{teuk},
        'mb656-838: rejected nick reuse leaves no pending merit');

    # [6] First public message consumes the candidate exactly once.
    my $consumer = bless {
        _comeback_pending => {
            teuk => {
                away_seconds => 45 * 86400,
                captured_at  => time(),
            },
        },
        checks => [],
    }, 'MB656ConsumeHarness';

    $assert->is($consumer->consume_comeback_candidate('Teuk', '#test'), 77,
        'mb656-838: first message consumes pending comeback');
    $assert->is(scalar(@{ $consumer->{checks} }), 1,
        'mb656-838: comeback check runs exactly once');
    $assert->is(join('|', @{ $consumer->{checks}[0] }),
        'Teuk|#test|' . (45 * 86400),
        'mb656-838: consume carries nick/channel/pre-JOIN duration');
    $assert->is($consumer->consume_comeback_candidate('Teuk', '#test'), 0,
        'mb656-838: second message cannot consume the same candidate');
    $assert->is(scalar(@{ $consumer->{checks} }), 1,
        'mb656-838: second message does not repeat the check');

    # [7] A stale pending candidate expires instead of granting merit later.
    my $expired = bless {
        _comeback_pending => {
            teuk => {
                away_seconds => 90 * 86400,
                captured_at  => time() - (25 * 60 * 60),
            },
        },
        checks => [],
    }, 'MB656ConsumeHarness';
    $assert->is($expired->consume_comeback_candidate('Teuk', '#test'), 0,
        'mb656-838: candidate older than 24h is discarded');
    $assert->is(scalar(@{ $expired->{checks} }), 0,
        'mb656-838: expired candidate cannot unlock anything');

    # [8] Runtime ordering is part of the safety contract:
    # JOIN samples before updateUserSeen; PRIVMSG consumes only after identity.
    my $main = slurp838('mediabot.pl');
    my ($join_body) = $main =~ /(sub on_message_JOIN \{.*?\n\})\n\s*sub on_message_001/s;
    $assert->ok(defined($join_body),
        'mb656-838: JOIN handler body is discoverable');
    if (defined $join_body) {
        my $capture_pos = index($join_body, 'note_comeback_candidate');
        my $seen_pos    = index($join_body, 'updateUserSeen');
        $assert->ok($capture_pos >= 0 && $seen_pos >= 0 && $capture_pos < $seen_pos,
            'mb656-838: comeback is sampled before JOIN refreshes USER_SEEN');
    }

    my ($priv_body) = $main =~ /(sub _on_message_PRIVMSG_body \{.*?\n\})\n\s*sub /s;
    $assert->ok(defined($priv_body),
        'mb656-838: PRIVMSG handler body is discoverable');
    if (defined $priv_body) {
        my $identity_pos = index($priv_body, 'observe_identity');
        my $consume_pos  = index($priv_body, 'consume_comeback_candidate');
        $assert->ok($identity_pos >= 0 && $consume_pos >= 0
                    && $identity_pos < $consume_pos,
            'mb656-838: pending comeback is consumed after live identity resolution');
        $assert->like($priv_body, qr/\$achievement_identity_ready/,
            'mb656-838: consumption is gated by successful identity resolution');
    }

    # [9] Feature remains schema-neutral.
    my $ach_src = slurp838('Mediabot/Achievements.pm');
    my ($check_body) = $ach_src =~ /(sub check_comeback \{.*?\n\})\n\n# -- Hook/s;
    $assert->ok(defined($check_body),
        'mb656-838: check_comeback body is discoverable');
    if (defined $check_body) {
        $assert->like($check_body, qr/->set_progress\('comeback_days'/,
            'mb656-838: comeback uses generic progress persistence');
        $assert->unlike($check_body,
            qr/\b(?:INSERT|UPDATE|DELETE|REPLACE|ALTER|CREATE|DROP)\b/i,
            'mb656-838: check_comeback contains no direct SQL/schema mutation');
    }
};
