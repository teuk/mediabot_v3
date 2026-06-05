# t/cases/384_schema_drift_refdata.t
# =============================================================================
# Tests unitaires pour la comparaison des donnees de reference du drift checker.
#
# Couvre :
#   - parsing des seeds CHANSET_LIST depuis install/mediabot.sql
#   - support INSERT INTO et INSERT IGNORE INTO
#   - detection d'un chanset manquant
#   - absence de bruit seed si la table CHANSET_LIST manque entierement
# =============================================================================

use strict;
use warnings;
use FindBin qw($Bin);
use File::Spec;
use File::Temp qw(tempfile);

my $script = File::Spec->catfile($Bin, '..', '..', 'tools', 'check_schema_drift.pl');

return sub {
    my ($assert) = @_;

    open my $fh, '<', $script or do {
        $assert->(0, "Cannot open $script: $!");
        return;
    };
    my $code = do { local $/; <$fh> };
    close $fh;

    my @subs = qw(
        defined_non_empty
        parse_reference_data_from_schema
        split_values_rows
        split_sql_values
        clean_sql_scalar
        compare_reference_data
        sql_quote
    );

    my $loaded = 0;
    for my $name (@subs) {
        if ($code =~ /(sub $name.*?^}\n)/sm) {
            eval $1;
            if ($@) { $assert->(0, "load $name: $@"); return; }
            $loaded++;
        }
    }

    $assert->($loaded == scalar(@subs), "loaded refdata helper subs");

    my ($tfh, $tmp) = tempfile('mediabot_refdata_XXXX', SUFFIX => '.sql', UNLINK => 1);

    print {$tfh} <<'SQL';
CREATE TABLE `CHANSET_LIST` (
  `id_chanset_list` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  `chanset` VARCHAR(255) NOT NULL,
  PRIMARY KEY (`id_chanset_list`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

INSERT INTO `CHANSET_LIST` (`id_chanset_list`, `chanset`) VALUES
(1, 'Youtube'),
(2, 'UrlTitle'),
(15, 'AchievementAnnounce');

INSERT IGNORE INTO `CHANSET_LIST` (`id_chanset_list`, `chanset`) VALUES
(16, 'Games'),
(17, 'Weird ''Quoted'' Chanset');
SQL

    close $tfh;

    my $ref = parse_reference_data_from_schema($tmp);

    $assert->(exists $ref->{CHANSET_LIST}, "CHANSET_LIST refdata parsed");
    $assert->(exists $ref->{CHANSET_LIST}{by_name}{youtube}, "Youtube parsed");
    $assert->(exists $ref->{CHANSET_LIST}{by_name}{achievementannounce}, "AchievementAnnounce parsed");
    $assert->(exists $ref->{CHANSET_LIST}{by_name}{games}, "Games parsed from INSERT IGNORE");
    $assert->(
        ($ref->{CHANSET_LIST}{by_name}{games}{id} // 0) == 16,
        "Games id parsed as 16"
    );
    $assert->(
        ($ref->{CHANSET_LIST}{by_name}{"weird 'quoted' chanset"}{id} // 0) == 17,
        "quoted scalar value unescaped correctly"
    );

    my $live = {
        CHANSET_LIST => {
            by_name => {
                youtube             => { id => 1,  chanset => 'Youtube' },
                urltitle            => { id => 2,  chanset => 'UrlTitle' },
                achievementannounce => { id => 15, chanset => 'AchievementAnnounce' },
            },
        },
    };

    my @issues;
    compare_reference_data($ref, $live, \@issues);

    my @missing = grep { $_->{kind} eq 'missing_chanset' } @issues;
    $assert->(@missing == 2, "two missing chansets detected");
    $assert->(
        grep { $_->{chanset} eq 'Games' && $_->{id} == 16 } @missing,
        "missing Games detected with id 16"
    );
    $assert->(
        grep { $_->{chanset} eq "Weird 'Quoted' Chanset" && $_->{id} == 17 } @missing,
        "missing quoted chanset detected with id 17"
    );

    my @issues_when_table_missing;
    my $live_missing_table = {
        CHANSET_LIST => {
            table_missing => 1,
        },
    };
    compare_reference_data($ref, $live_missing_table, \@issues_when_table_missing);

    $assert->(
        @issues_when_table_missing == 0,
        "no seed-row noise when CHANSET_LIST table is missing"
    );

    my $quoted = sql_quote("O'Hara");
    $assert->($quoted eq "'O''Hara'", "sql_quote escapes single quotes");
};
