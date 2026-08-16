# t/cases/826_mb646_achievements_db_identity.t
# =============================================================================
# mb646 — achievements are DB-backed after migration and IRC identity matching
# is conservative across nick / user@host variation.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Temp qw(tempdir);

sub slurp826 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "$path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    require Mediabot::Achievements;

    # [1] Pure identity compatibility rules.
    $assert->ok(
        Mediabot::Achievements::_userhost_compatible('~teuk@host.example', 'teuk@host.example'),
        'mb646-826: ident ~ variation is compatible');
    $assert->ok(
        Mediabot::Achievements::_userhost_compatible('teuk@old.example', 'teuk@new.example'),
        'mb646-826: same ident can follow a host change');
    $assert->ok(
        Mediabot::Achievements::_userhost_compatible('oldident@host.example', 'newident@host.example'),
        'mb646-826: same host can follow an ident change');
    $assert->ok(
        !Mediabot::Achievements::_userhost_compatible('alice@one.example', 'bob@two.example'),
        'mb646-826: unrelated userhosts are not merged');
    $assert->ok(
        Mediabot::Achievements::_userhost_compatible('', 'teuk@host.example'),
        'mb646-826: legacy JSON empty userhost can attach on first live sighting');

    # [2] Legacy/no-DB mode remains functional for old installations/tests.
    my $dir = tempdir(CLEANUP => 1);
    my $a = Mediabot::Achievements->new(path => "$dir/ach.json", bot => undef);
    $assert->is($a->{storage}, 'json',
        'mb646-826: missing DB migration falls back to JSON instead of crashing');
    $assert->is($a->bump_progress('mood', 'Teuk', '#Chan'), 1,
        'mb646-826: JSON fallback still persists progress');
    $a->unlock('Teuk', '#Chan', 'first_msg');
    $assert->ok(exists $a->get_for_nick('teuk', '#chan')->{first_msg},
        'mb646-826: JSON fallback still persists unlocks');

    # [3] Reference schema + idempotent migration carry the four durable tables.
    my $schema = slurp826('install/mediabot.sql');
    my $mig    = slurp826('install/migrations/20260816_achievements_db.sql');
    for my $table (qw(
        ACHIEVEMENT_PROFILE ACHIEVEMENT_IDENTITY
        ACHIEVEMENT_UNLOCK ACHIEVEMENT_PROGRESS
    )) {
        $assert->like($schema, qr/CREATE TABLE `\Q$table\E`/,
            "mb646-826: reference schema contains $table");
        $assert->like($mig, qr/CREATE TABLE IF NOT EXISTS `\Q$table\E`/,
            "mb646-826: migration creates $table idempotently");
    }
    $assert->like($schema,
        qr/UNIQUE KEY `uq_achievement_identity_triplet` \(`id_channel`, `nick`, `userhost`\)/,
        'mb646-826: exact channel+nick+userhost triplet is unique');

    # [4] Runtime observes identity before achievement-producing hooks.
    my $main = slurp826('mediabot.pl');
    my $observe_pos = index($main, '->observe_identity(');
    my $trivia_pos  = index($main, 'checkTriviaAnswer(');
    my $queue_pos   = index($main, '->queue_check(');
    $assert->ok($observe_pos >= 0 && $trivia_pos > $observe_pos,
        'mb646-826: identity is bound before trivia can mutate progress');
    $assert->ok($queue_pos > $observe_pos,
        'mb646-826: identity is bound before async msg achievement queue');

    # [5] Update transition never silently strands the legacy JSON.
    my $deploy = slurp826('install/deploy_update.sh');
    $assert->like($deploy,
        qr{PROJECT_DIR\}/var/achievements\.json.*?TMP_CLONE_DIR\}/var/achievements\.json}s,
        'mb646-826: updater carries legacy JSON into staged release for one-time import');

    # [6] Presentation code no longer depends on internal JSON hashes.
    my $uc = slurp826('Mediabot/UserCommands.pm');
    $assert->ok(index($uc, '$self->{achievements}{data}') < 0,
        'mb646-826: UserCommands no longer reaches into achievement data internals');
    $assert->like($uc, qr/channel_unlock_count\(\$channel\)/,
        'mb646-826: dashboard uses storage-neutral aggregate API');
    $assert->like($uc, qr/top_on_channel\(\$channel,\s*3\)/,
        'mb646-826: leaderboard uses storage-neutral aggregate API');

    # [7] Public contract: DB first, JSON guarded fallback/import.
    my $ach = slurp826('Mediabot/Achievements.pm');
    $assert->like($ach, qr/sub _db_schema_available \{/,
        'mb646-826: DB schema capability is detected at runtime');
    $assert->like($ach, qr/sub _import_legacy_json_if_present \{/,
        'mb646-826: legacy state has an explicit DB importer');
    $assert->like($ach, qr/sub observe_identity \{/,
        'mb646-826: durable identity observation exists');

    # [8] The production Mediabot object is a blessed HASH. Schema probing must
    # accept that real runtime shape instead of requiring ref($bot) eq 'HASH'.
    {
        package MB646SchemaSTH;
        sub new { bless {}, $_[0] }
        sub execute { 1 }
        sub fetchrow_array { return (4) }
        sub finish { 1 }

        package MB646SchemaDBH;
        sub new { bless {}, $_[0] }
        sub prepare { return MB646SchemaSTH->new }

        package main;
        my $runtime_bot = bless {
            dbh => MB646SchemaDBH->new,
        }, 'Mediabot';
        my $schema_probe = bless {
            bot => $runtime_bot,
        }, 'Mediabot::Achievements';

        $assert->ok($schema_probe->_db_schema_available,
            'mb646-826: schema probe accepts the real blessed Mediabot hash shape');
    }

    # [9] Message-derived achievements use every known alias of the durable
    # profile, not only the currently visible nick. This matters for long
    # thresholds after a nick change.
    {
        package MB646AliasSTH;
        sub new { bless { rows => $_[1], pos => 0 }, $_[0] }
        sub execute { 1 }
        sub fetchrow_hashref {
            my ($self) = @_;
            return undef if $self->{pos} >= @{ $self->{rows} };
            return $self->{rows}[ $self->{pos}++ ];
        }
        sub finish { 1 }

        package MB646AliasDBH;
        sub new { bless {}, $_[0] }
        sub prepare {
            return MB646AliasSTH->new([
                { nick => 'NewNick', userhost => '~teuk@cloak.example' },
                { nick => 'OldNick', userhost => 'teuk@cloak.example' },
            ]);
        }

        package main;
        my $fake = bless {
            storage => 'db',
            _worker_profile_id => 42,
            bot => { dbh => MB646AliasDBH->new },
        }, 'Mediabot::Achievements';

        my ($sql, @bind) = $fake->_worker_identity_sql('cl', 'NewNick');
        $assert->like($sql, qr/cl\.nick = \? AND cl\.userhost = \?/,
            'mb646-826: worker history predicate binds nick+userhost aliases');
        $assert->is(join("\x1f", @bind), join("\x1f",
            'NewNick', '~teuk@cloak.example',
            'OldNick', 'teuk@cloak.example'),
            'mb646-826: worker history scan carries old and new aliases');

        $assert->like($ach, qr/profile_id\s*=>\s*\$entry->\{profile_id\}/,
            'mb646-826: async queue carries durable profile id into worker');
        $assert->like($ach, qr/_worker_profile_id\}\s*=\s*\$job->\{profile_id\}/,
            'mb646-826: child worker receives durable profile id');
    }

};
