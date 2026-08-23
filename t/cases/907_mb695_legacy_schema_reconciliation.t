# t/cases/907_mb695_legacy_schema_reconciliation.t
use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

return sub {
    my ($assert) = @_;

    my $migration = File::Spec->catfile(
        '.', 'install', 'migrations', '20260823_legacy_schema_reconciliation.sql'
    );
    my $readme = File::Spec->catfile('.', 'install', 'migrations', 'README.md');

    open my $mf, '<', $migration or do {
        $assert->ok(0, "cannot open $migration: $!");
        return;
    };
    my $sql = do { local $/; <$mf> };
    close $mf;

    open my $rf, '<', $readme or do {
        $assert->ok(0, "cannot open $readme: $!");
        return;
    };
    my $doc = do { local $/; <$rf> };
    close $rf;

    $assert->like(
        $sql,
        qr/CREATE PROCEDURE `mb695_assert_safe`/,
        'mb695-907: migration has fail-closed live-data preconditions',
    );

    for my $guard (
        'ACTIONS_QUEUE has duplicate ids',
        'TIMERS.duration is outside signed INT range',
        'NETWORK has 191-char unique-prefix collisions',
        'FACTOID has orphan id_channel values',
        'REMINDERS has orphan id_channel values',
        'TRIVIA_SCORES has orphan id_channel values',
    ) {
        $assert->like(
            $sql,
            qr/\Q$guard\E/,
            "mb695-907: safety guard present: $guard",
        );
    }

    my @converts = ($sql =~ /CALL `mb695_convert_table`\('([A-Z0-9_]+)'\);/g);
    $assert->is(
        scalar(@converts),
        27,
        'mb695-907: exactly the 27 audited legacy table defaults are normalized',
    );

    for my $table (qw(
        ACTIONS_LOG ACTIONS_QUEUE BADWORDS BOT_ALIAS CHANNEL_FLOOD
        CHANNEL_PURGED CHANNEL_SET CHANSET_LIST CONSOLE HAILO_CHANNEL
        HAILO_EXCLUSION_NICK IGNORES KARMA MP3 NETWORK PUBLIC_COMMANDS
        PUBLIC_COMMANDS_CATEGORY QUOTES REMINDERS SERVERS TIMERS TIMEZONE
        USER USER_CHANNEL USER_LEVEL WEBLOG YOMOMMA
    )) {
        $assert->ok(
            grep { $_ eq $table } @converts,
            "mb695-907: audited charset normalization includes $table",
        );
    }

    for my $index_call (
        q{CALL `mb695_fix_single_index`('CHANNEL_LOG','userhost','userhost',191,0)},
        q{CALL `mb695_fix_single_index`('PUBLIC_COMMANDS','command','command',191,1)},
        q{CALL `mb695_fix_single_index`('TIMERS','name','name',191,1)},
    ) {
        $assert->like(
            $sql,
            qr/\Q$index_call\E/,
            "mb695-907: canonical helper-managed prefix index repair is explicit",
        );
    }

    $assert->like(
        $sql,
        qr/ALTER\s+TABLE\s+`NETWORK`\s+DROP\s+INDEX\s+IF\s+EXISTS\s+`network_name`\s*;/is,
        'mb695-907: NETWORK historical index is explicitly rebuilt',
    );

    $assert->like(
        $sql,
        qr/ALTER\s+TABLE\s+`NETWORK`\s+ADD\s+UNIQUE\s+INDEX\s+`network_name`\s+\(`network_name`\(191\)\)\s*;/is,
        'mb695-907: NETWORK canonical 191-char unique prefix index is Doctor-observable',
    );

    $assert->unlike(
        $sql,
        qr/CALL\s+`mb695_fix_single_index`\('NETWORK','network_name','network_name',191,1\)/,
        'mb695-907: NETWORK repair is not hidden behind a stored helper',
    );

    for my $fk (qw(
        fk_channel_user
        fk_factoid_channel
        fk_factoid_created_by
        fk_karma_channel
        fk_pc_user
        fk_pc_category
        fk_reminders_channel
        fk_trivia_scores_channel
    )) {
        $assert->like(
            $sql,
            qr/\Q$fk\E/,
            "mb695-907: canonical FK is covered: $fk",
        );
    }

    $assert->like(
        $sql,
        qr/USER\.hostmasks_legacy is intentionally preserved/,
        'mb695-907: known legacy hostmask compatibility data is explicitly preserved',
    );

    $assert->unlike(
        $sql,
        qr/DROP\s+COLUMN\s+`?hostmasks_legacy`?/i,
        'mb695-907: migration never drops USER.hostmasks_legacy',
    );

    $assert->unlike(
        $sql,
        qr/\b(?:DELETE\s+FROM|TRUNCATE\s+TABLE|DROP\s+TABLE)\b/i,
        'mb695-907: migration contains no row/table destruction',
    );

    $assert->like(
        $doc,
        qr/^20260822_rss_feeds\.sql\R20260823_legacy_schema_reconciliation\.sql$/m,
        'mb695-907: migration order places legacy reconciliation after RSS',
    );

    $assert->like(
        $doc,
        qr/Long-lived database reconciliation/,
        'mb695-907: migration README documents the compatibility purpose',
    );
};
