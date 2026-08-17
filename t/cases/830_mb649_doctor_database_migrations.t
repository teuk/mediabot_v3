# t/cases/830_mb649_doctor_database_migrations.t
# =============================================================================
# mb649 — Mediabot Doctor round 3: database + migrations, strictly read-only.
#
# Locks the semantics rather than a particular live database:
#   - database uses the non-fatal isolated connector, never Mediabot::DB->new();
#   - a read-only session is mandatory before Doctor queries;
#   - schema drift remains delegated to tools/check_schema_drift.pl;
#   - MB646 complete/absent/partial storage has distinct severity;
#   - migration history is never invented: only observable_effect_present,
#     observable_effect_missing, or indeterminate are reported.
# =============================================================================

use strict;
use warnings;
use utf8;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;
use File::Temp qw(tempdir tempfile);

my $ROOT = File::Spec->catdir($Bin, '..', '..');
my $TOOL = File::Spec->catfile($ROOT, 'tools', 'mediabot_doctor.pl');

return sub {
    my ($assert) = @_;

    my $loaded = do $TOOL;
    $assert->ok($loaded, 'mb649-830: Doctor loads');
    $assert->is($main::PROBES{database}{round}, 3,
        'mb649-830: database probe is implemented in round 3');
    $assert->is($main::PROBES{migrations}{round}, 3,
        'mb649-830: migrations probe is implemented in round 3');

    open my $tfh, '<', $TOOL or die $!;
    local $/;
    my $source = <$tfh>;
    close $tfh;
    (my $code_only = $source) =~ s/^\s*#.*$//mg;
    $assert->unlike($code_only, qr/Mediabot::DB\s*->\s*new\s*\(/,
        'mb649-830: Doctor never calls fatal Mediabot::DB->new()');
    $assert->like($source, qr/connect_isolated_handle\s*\(/,
        'mb649-830: Doctor reuses the non-fatal isolated DB connector');
    $assert->like($source, qr/SET SESSION TRANSACTION READ ONLY/,
        'mb649-830: Doctor enforces a read-only DB session before queries');
    $assert->like($source, qr/check_schema_drift\.pl.*--ignore-extra/s,
        'mb649-830: schema truth is delegated to the existing drift checker');

    # ------------------------------------------------------------------
    # [1] bounded subprocess helper
    # ------------------------------------------------------------------
    my $quick = main::_capture_command_bounded(2, $^X, '-e', 'print "ok\\n"');
    $assert->ok($quick->{ok}, 'mb649-830: bounded child captures a successful command');
    $assert->like($quick->{stdout}, qr/^ok/m,
        'mb649-830: bounded child captures stdout');

    my $slow = main::_capture_command_bounded(0.1, $^X, '-e', 'select undef,undef,undef,1');
    $assert->is($slow->{rc}, 124,
        'mb649-830: bounded child times out instead of hanging Doctor');
    $assert->ok($slow->{timeout}, 'mb649-830: timeout is explicit');

    $assert->unlike(main::_sanitize_diag_text('password=hunter2 token=abc'), qr/hunter2|abc/,
        'mb649-830: diagnostic text redacts obvious secret assignments');

    # ------------------------------------------------------------------
    # [2] database evaluator is pure and grades the important states
    # ------------------------------------------------------------------
    my $dprobe = $main::PROBES{database};
    my @req = qw(ACHIEVEMENT_PROFILE ACHIEVEMENT_IDENTITY ACHIEVEMENT_UNLOCK ACHIEVEMENT_PROGRESS);
    my @tables = map { { TABLE_NAME => $_, ENGINE => 'InnoDB', TABLE_COLLATION => 'utf8mb4_unicode_ci' } } @req;
    my $safe_raw = {
        connected => 1,
        meta => { dbname => 'mediabotv3', dbhost => '127.0.0.1', dbport => 3306,
                  charset_mode => 'utf8mb4', driver => 'MariaDB', driver_version => '1.23' },
        session => { dbname => 'mediabotv3', server_version => '10.11-test',
                     character_set_client => 'utf8mb4', character_set_connection => 'utf8mb4',
                     character_set_results => 'utf8mb4', collation_connection => 'utf8mb4_unicode_ci' },
        achievement_required => \@req,
        achievement_tables => \@tables,
        schema_drift => { ok => 1, rc => 0, stdout => '', stderr => '' },
    };
    my @safe = $dprobe->{evaluate}->($safe_raw, {});
    my %safe = map { $_->{id} => $_ } @safe;
    $assert->is($safe{'database.connection'}{level}, 'ok',
        'mb649-830: safe DB connection is OK');
    $assert->ok($safe{'database.connection'}{data}{read_only_enforced},
        'mb649-830: read-only enforcement remains machine-visible');
    $assert->is($safe{'database.session_charset'}{level}, 'ok',
        'mb649-830: matching utf8mb4 session is OK');
    $assert->is($safe{'database.achievement_storage'}{level}, 'ok',
        'mb649-830: all four MB646 tables mean DB storage is available');
    $assert->is($safe{'database.achievement_storage'}{data}{storage}, 'db',
        'mb649-830: achievement storage reports db');
    $assert->is($safe{'database.schema_drift'}{level}, 'ok',
        'mb649-830: delegated clean schema is OK');

    my $missing_raw = { %$safe_raw, achievement_tables => [] };
    my %missing = map { $_->{id} => $_ } $dprobe->{evaluate}->($missing_raw, {});
    $assert->is($missing{'database.achievement_storage'}{level}, 'warn',
        'mb649-830: all MB646 tables absent is supported JSON fallback, not fake OK');
    $assert->is($missing{'database.achievement_storage'}{data}{storage}, 'json_fallback',
        'mb649-830: fallback storage is explicit');

    my $partial_raw = { %$safe_raw, achievement_tables => [ $tables[0], $tables[1] ] };
    my %partial = map { $_->{id} => $_ } $dprobe->{evaluate}->($partial_raw, {});
    $assert->is($partial{'database.achievement_storage'}{level}, 'fail',
        'mb649-830: partial MB646 schema is FAIL');

    my $drift_raw = { %$safe_raw, schema_drift => { ok => 0, rc => 1, stdout => 'MISSING TABLE X', stderr => '' } };
    my %drift = map { $_->{id} => $_ } $dprobe->{evaluate}->($drift_raw, {});
    $assert->is($drift{'database.schema_drift'}{level}, 'fail',
        'mb649-830: missing required table remains FAIL');
    $assert->ok($drift{'database.schema_drift'}{data}{critical_missing},
        'mb649-830: missing table is machine-visible as critical missing state');
    $assert->like($drift{'database.schema_drift'}{detail}, qr/MISSING TABLE X/,
        'mb649-830: drift evidence stays visible');

    my $index_drift_raw = { %$safe_raw, schema_drift => { ok => 0, rc => 1,
        stdout => 'INDEX DRIFT CHANNEL_LOG.userhost expected=[nonunique|userhost(191)] live=[nonunique|userhost]', stderr => '' } };
    my %index_drift = map { $_->{id} => $_ } $dprobe->{evaluate}->($index_drift_raw, {});
    $assert->is($index_drift{'database.schema_drift'}{level}, 'warn',
        'mb649-830: type/index-only schema drift is WARN, not UNSAFE');
    $assert->ok(!$index_drift{'database.schema_drift'}{data}{critical_missing},
        'mb649-830: metadata/index drift is not mislabelled as missing runtime object');

    my @offline = $dprobe->{evaluate}->({ connected => 0, meta => { error => 'connection refused' } }, {});
    $assert->is($offline[0]{level}, 'unknown',
        'mb649-830: unavailable DB is UNKNOWN, not reassuring OK or alarmist FAIL');

    # ------------------------------------------------------------------
    # [3] every CURRENT migration exposes a durable observable signature
    # ------------------------------------------------------------------
    my $mdir = File::Spec->catdir($ROOT, 'install', 'migrations');
    opendir(my $dh, $mdir) or die $!;
    my @files = sort grep { /\.sql$/ } readdir($dh);
    closedir $dh;
    $assert->is(scalar(@files), 18,
        'mb649-830: current migration inventory contains 18 SQL files');
    for my $name (@files) {
        my $spec = main::_migration_observables(File::Spec->catfile($mdir, $name));
        $assert->ok(@{ $spec->{effects} || [] } > 0,
            "mb649-830: $name has at least one observable durable effect");
        $assert->ok(!$spec->{unsupported_mutation},
            "mb649-830: $name has no unmodelled durable mutation");
    }

    my $quotes = main::_migration_observables(File::Spec->catfile($mdir, '20260710_quotes_hits.sql'));
    $assert->ok((grep { $_->{type} eq 'column' && $_->{table} eq 'QUOTES' && $_->{column} eq 'hits' } @{ $quotes->{effects} }),
        'mb649-830: dynamic QUOTES.hits column is observable');
    $assert->ok((grep { $_->{type} eq 'index' && $_->{index} eq 'idx_quotes_channel_hits' } @{ $quotes->{effects} }),
        'mb649-830: dynamic QUOTES index is observable');

    my $lang = main::_migration_observables(File::Spec->catfile($mdir, '20260724_lang_chansets.sql'));
    $assert->ok((grep { $_->{type} eq 'chanset' && $_->{chanset} eq 'LangFR' } @{ $lang->{effects} }),
        'mb649-830: data-only LangFR chanset is observable');
    $assert->ok((grep { $_->{type} eq 'chanset' && $_->{chanset} eq 'LangES' } @{ $lang->{effects} }),
        'mb649-830: data-only LangES chanset is observable');

    my $trivia = main::_migration_observables(File::Spec->catfile($mdir, '20260521_trivia_scores_note.sql'));
    $assert->ok((grep { $_->{type} eq 'constraint' && $_->{constraint} eq 'fk_trivia_scores_channel' } @{ $trivia->{effects} }),
        'mb649-830: dynamic foreign-key constraint is observable');

    # ------------------------------------------------------------------
    # [4] migration evaluator never claims historical execution
    # ------------------------------------------------------------------
    my $mprobe = $main::PROBES{migrations};
    my $present = {
        migrations => [
            { name => 'a.sql', effects => [ { type => 'table', table => 'A' } ],
              observed => [ { type => 'table', table => 'A', state => 'present' } ] },
            { name => 'b.sql', effects => [ { type => 'chanset', chanset => 'B' } ],
              observed => [ { type => 'chanset', chanset => 'B', state => 'present' } ] },
        ],
    };
    my %mp = map { $_->{id} => $_ } $mprobe->{evaluate}->($present, {});
    $assert->is($mp{'migrations.observable_state'}{level}, 'ok',
        'mb649-830: all observable effects present is OK');
    $assert->is($mp{'migrations.observable_state'}{data}{historical_execution_proven}, 0,
        'mb649-830: present effects never pretend to prove migration execution history');
    $assert->unlike($mp{'migrations.observable_state'}{summary}, qr/\bapplied\b/i,
        'mb649-830: human summary never says migration applied');

    my $missing_effect = {
        migrations => [
            { name => 'a.sql', effects => [ { type => 'table', table => 'A' } ],
              observed => [ { type => 'table', table => 'A', state => 'missing' } ] },
        ],
    };
    my %mm = map { $_->{id} => $_ } $mprobe->{evaluate}->($missing_effect, {});
    $assert->is($mm{'migrations.observable_state'}{level}, 'warn',
        'mb649-830: missing observable effect is WARN');
    $assert->is($mm{'migrations.observable_state'}{data}{states}[0]{state}, 'observable_effect_missing',
        'mb649-830: missing state uses the explicit observable_effect_missing vocabulary');
    $assert->like($mm{'migrations.observable_state'}{detail}, qr/table A/,
        'mb649-830: missing migration detail names the concrete observable effect');
    $assert->like($mm{'migrations.observable_state'}{detail}, qr/does NOT prove/i,
        'mb649-830: missing observable effect never claims historical non-execution');

    my $indeterminate = {
        migrations => [
            { name => 'future.sql', effects => [], unsupported_mutation => 1, observed => [] },
        ],
    };
    my %mi = map { $_->{id} => $_ } $mprobe->{evaluate}->($indeterminate, {});
    $assert->is($mi{'migrations.observable_state'}{level}, 'unknown',
        'mb649-830: unmodelled migration remains UNKNOWN');
    $assert->is($mi{'migrations.observable_state'}{data}{states}[0]{state}, 'indeterminate',
        'mb649-830: unprovable migration uses indeterminate vocabulary');
};
