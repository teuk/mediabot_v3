# t/cases/898_mb692_fresh_schema_drift_truth.t
use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

my $tool = File::Spec->catfile('.', 'tools', 'check_schema_drift.pl');

return sub {
    my ($assert) = @_;

    open my $fh, '<', $tool or do {
        $assert->ok(0, "cannot open $tool: $!");
        return;
    };
    my $code = do { local $/; <$fh> };
    close $fh;

    my @subs = qw(
        defined_non_empty
        split_create_table_items
        parse_index_item
        is_table_constraint
        is_reserved_or_attribute_identifier
        normalize_create_table
        parse_schema_file
        _normalize_integer_display_widths
        _lowercase_sql_outside_single_quotes
        normalize_column_def
        normalize_live_column_def
    );

    my $loaded = 0;
    for my $name (@subs) {
        if ($code =~ /(sub \Q$name\E.*?^}\n)/sm) {
            eval $1;
            if ($@) {
                $assert->ok(0, "load $name: $@");
                return;
            }
            $loaded++;
        }
    }

    $assert->is(
        $loaded,
        scalar(@subs),
        'mb692-898: loaded drift parser/normalization helpers',
    );

    my $schema = parse_schema_file(
        File::Spec->catfile('.', 'install', 'mediabot.sql')
    );

    $assert->ok(
        exists $schema->{CHANNEL}{columns}{key},
        'mb692-898: quoted CHANNEL.key remains a reference column',
    );

    $assert->ok(
        exists $schema->{CHANNEL_PURGED}{columns}{key},
        'mb692-898: quoted CHANNEL_PURGED.key remains a reference column',
    );

    my $tmdb_ref = $schema->{CHANNEL}{columns}{tmdb_lang}{definition};
    my $tmdb_live = {
        type => 'varchar(255)',
        nullable => 'NO',
        default => q{'en-US'},
        extra => '',
        charset => 'utf8mb4',
        collation => 'utf8mb4_unicode_ci',
    };

    $assert->is(
        normalize_live_column_def($tmdb_live, $tmdb_ref),
        normalize_column_def($tmdb_ref),
        'mb692-898: CHANNEL.tmdb_lang en-US has no false type drift',
    );

    my $automode_ref =
        $schema->{USER_CHANNEL}{columns}{automode}{definition};
    my $automode_live = {
        type => 'varchar(255)',
        nullable => 'NO',
        default => q{'NONE'},
        extra => '',
        charset => 'utf8mb4',
        collation => 'utf8mb4_unicode_ci',
    };

    $assert->is(
        normalize_live_column_def($automode_live, $automode_ref),
        normalize_column_def($automode_ref),
        'mb692-898: USER_CHANNEL.automode NONE has no false type drift',
    );

    my $wrong_case = { %$tmdb_live, default => q{'en-us'} };

    $assert->isnt(
        normalize_live_column_def($wrong_case, $tmdb_ref),
        normalize_column_def($tmdb_ref),
        'mb692-898: a real string-default case drift remains detectable',
    );
};
