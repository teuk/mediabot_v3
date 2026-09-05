use strict;
use warnings;
use FindBin qw($Bin);
use File::Spec;

my $script = File::Spec->catfile($Bin, '..', '..', 'tools', 'check_schema_drift.pl');

return sub {
    my ($assert) = @_;

    open my $fh, '<', $script or do { $assert->(0, "Cannot open $script: $!"); return; };
    my $code = do { local $/; <$fh> };
    close $fh;

    my @subs = qw(defined_non_empty _normalize_integer_display_widths _lowercase_sql_outside_single_quotes normalize_column_def normalize_live_column_def);
    my $loaded = 0;
    for my $name (@subs) {
        if ($code =~ /(sub \Q$name\E.*?^}\n)/sm) {
            eval $1;
            if ($@) { $assert->(0, "load $name: $@"); return; }
            $loaded++;
        }
    }
    $assert->is($loaded, scalar(@subs), 'mb649-831: loaded schema type-normalization helpers');

    my $bigint_ref = 'BIGINT UNSIGNED NOT NULL AUTO_INCREMENT';
    my $bigint_live = {
        type => 'bigint(20) unsigned', nullable => 'NO', default => undef,
        extra => 'auto_increment', charset => '', collation => '',
    };
    $assert->is(
        normalize_live_column_def($bigint_live, $bigint_ref),
        normalize_column_def($bigint_ref),
        'mb649-831: MariaDB BIGINT(20) display width matches width-less BIGINT reference',
    );

    my $int_ref = 'INT(11) NOT NULL DEFAULT 0';
    my $int_live = {
        type => 'int(11)', nullable => 'NO', default => 0,
        extra => '', charset => '', collation => '',
    };
    $assert->is(
        normalize_live_column_def($int_live, $int_ref),
        normalize_column_def($int_ref),
        'mb649-831: legacy INT display width canonicalizes consistently on both sides',
    );

    my $utf_ref = 'VARCHAR(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NOT NULL';
    my $utf_live = {
        type => 'varchar(255)', nullable => 'NO', default => undef, extra => '',
        charset => 'utf8mb4', collation => 'utf8mb4_unicode_ci',
    };
    $assert->is(
        normalize_live_column_def($utf_live, $utf_ref),
        normalize_column_def($utf_ref),
        'mb649-831: explicit utf8mb4 charset/collation matches live metadata',
    );

    my $wrong_utf = { %$utf_live, charset => 'utf8mb3', collation => 'utf8mb3_unicode_ci' };
    $assert->isnt(
        normalize_live_column_def($wrong_utf, $utf_ref),
        normalize_column_def($utf_ref),
        'mb649-831: explicit charset/collation mismatch remains visible',
    );

    my $implicit_ref = 'VARCHAR(255) NOT NULL';
    $assert->is(
        normalize_live_column_def($wrong_utf, $implicit_ref),
        normalize_column_def($implicit_ref),
        'mb649-831: inherited charset is not invented into a column definition that does not declare it',
    );

    my $nullable_ref = 'DATETIME NULL DEFAULT NULL';
    my $nullable_live = {
        type => 'datetime', nullable => 'YES', default => undef,
        extra => '', charset => '', collation => '',
    };
    $assert->is(
        normalize_live_column_def($nullable_live, $nullable_ref),
        normalize_column_def($nullable_ref),
        'mb649-831: explicit nullable DEFAULT NULL canonicalizes to information_schema representation',
    );


    my $nullable_sql_null_live = {
        type => 'bigint(20) unsigned', nullable => 'YES', default => 'NULL',
        extra => '', charset => '', collation => '',
    };
    $assert->is(
        normalize_live_column_def($nullable_sql_null_live, 'BIGINT UNSIGNED'),
        normalize_column_def('BIGINT UNSIGNED'),
        'mb649-831: MariaDB SQL-token NULL for implicit nullable default is canonicalized away',
    );

    my $quoted_default_ref = q{VARCHAR(32) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT 'irc'};
    my $quoted_default_live = {
        type => 'varchar(32)', nullable => 'NO', default => q{'irc'},
        extra => '', charset => 'utf8mb4', collation => 'utf8mb4_unicode_ci',
    };
    $assert->is(
        normalize_live_column_def($quoted_default_live, $quoted_default_ref),
        normalize_column_def($quoted_default_ref),
        'mb649-831: MariaDB already-quoted string default is not double quoted',
    );

    my $empty_default_ref = q{VARCHAR(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT ''};
    my $empty_default_live = {
        type => 'varchar(255)', nullable => 'NO', default => q{''},
        extra => '', charset => 'utf8mb4', collation => 'utf8mb4_unicode_ci',
    };
    $assert->is(
        normalize_live_column_def($empty_default_live, $empty_default_ref),
        normalize_column_def($empty_default_ref),
        'mb649-831: empty quoted MariaDB default remains exactly one SQL literal',
    );

    my $case_default_live = { %$quoted_default_live, default => q{'IRC'} };
    $assert->isnt(
        normalize_live_column_def($case_default_live, $quoted_default_ref),
        normalize_column_def($quoted_default_ref),
        'mb649-831: quoted literal case differences remain observable',
    );

    my $mixed_case_default_ref = q{VARCHAR(32) NOT NULL DEFAULT 'en-US'};
    my $mixed_case_default_live = {
        type => 'varchar(32)', nullable => 'NO', default => q{'en-US'},
        extra => '', charset => '', collation => '',
    };
    $assert->is(
        normalize_live_column_def($mixed_case_default_live, $mixed_case_default_ref),
        normalize_column_def($mixed_case_default_ref),
        'mb692-ci: matching mixed-case string defaults remain equal',
    );
    $assert->like(
        normalize_column_def($mixed_case_default_ref),
        qr/default 'en-US'\z/,
        'mb692-ci: reference normalization preserves literal case',
    );

    my $comment_ref = q{TINYINT NOT NULL DEFAULT 1 COMMENT 'runtime flag'};
    my $comment_live = {
        type => 'tinyint(4)', nullable => 'NO', default => 1,
        extra => '', charset => '', collation => '',
    };
    $assert->is(
        normalize_live_column_def($comment_live, $comment_ref),
        normalize_column_def($comment_ref),
        'mb649-831: column COMMENT is excluded from --types comparison',
    );

    my $fractional_timestamp_ref =
        'DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3)';
    my $fractional_timestamp_live = {
        type => 'datetime(3)', nullable => 'NO', default => 'current_timestamp(3)',
        extra => 'on update current_timestamp(3)', charset => '', collation => '',
    };
    $assert->is(
        normalize_live_column_def($fractional_timestamp_live, $fractional_timestamp_ref),
        normalize_column_def($fractional_timestamp_ref),
        'mb724-ci: MariaDB fractional CURRENT_TIMESTAMP metadata remains an SQL expression',
    );

    my $quoted_fractional_timestamp_live = {
        %$fractional_timestamp_live,
        default => q{'current_timestamp(3)'},
    };
    $assert->isnt(
        normalize_live_column_def($quoted_fractional_timestamp_live, $fractional_timestamp_ref),
        normalize_column_def($fractional_timestamp_ref),
        'mb724-ci: a quoted timestamp-looking literal remains distinguishable from the SQL expression',
    );

    $assert->like($code, qr/normalize_live_column_def\([^;]+\{definition\}\)/s,
        'mb649-831: live normalization receives the reference definition for explicit charset semantics');
};
