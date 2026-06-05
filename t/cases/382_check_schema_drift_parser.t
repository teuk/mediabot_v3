# t/cases/382_check_schema_drift_parser.t
# =============================================================================
# Tests unitaires pour le parser de tools/check_schema_drift.pl
#
# Sont couverts :
#   - split_create_table_items: multi-ligne, parenthèses imbriquées, strings
#     avec virgules/parens/escapes, commentaires SQL `-- ...` inline
#   - is_reserved_or_attribute_identifier: garde-fou pour les mots-cles
#   - is_table_constraint: detection des PRIMARY/KEY/UNIQUE/FOREIGN/CHECK
#
# Pourquoi ces tests :
#   Avant mb118-119, le script generait du SQL casse pour KARMA_LOG parce que
#   la definition multi-ligne de la colonne `ts` etait mal parsee. Avant mb120,
#   un commentaire SQL `-- foo` au milieu d'une definition de table cassait
#   silencieusement le parser. Ces tests verrouillent les corrections.
# =============================================================================

use strict;
use warnings;
use FindBin qw($Bin);
use File::Spec;

# Charger les subs du script en evaluant les blocs de code (sans les imports
# DBI qui ne sont pas requis pour ces tests purs).
my $script = File::Spec->catfile($Bin, '..', '..', 'tools', 'check_schema_drift.pl');

return sub {
    my ($assert) = @_;

    open my $fh, '<', $script or do {
        $assert->(0, "Cannot open $script: $!");
        return;
    };
    my $code = do { local $/; <$fh> };
    close $fh;

    my $loaded = 0;
    for my $name (qw(split_create_table_items is_table_constraint is_reserved_or_attribute_identifier)) {
        if ($code =~ /(sub $name.*?^}\n)/sm) {
            eval $1;
            if ($@) { $assert->(0, "load $name: $@"); return; }
            $loaded++;
        }
    }
    $assert->($loaded == 3, "loaded 3 parser subs (got $loaded)");

    # -------------------------------------------------------------------------
    # Test 1: definition multi-ligne avec COMMENT sur ligne suivante
    # (le bug originel, fixe par Christophe en mb119)
    # -------------------------------------------------------------------------
    my $body1 = q{
        `id` INT NOT NULL,
        `ts` DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
             COMMENT 'Vote timestamp',
        PRIMARY KEY (`id`)
    };
    my @items1 = split_create_table_items($body1);
    $assert->(scalar(@items1) == 3,
        "multiline COMMENT: 3 items (got " . scalar(@items1) . ")");

    # -------------------------------------------------------------------------
    # Test 2: SQL line comment '-- ...' en milieu de body (bug B1 mb120)
    # -------------------------------------------------------------------------
    my $body2 = q{
        `id` INT, -- a comment with, commas, inside
        `name` VARCHAR(64),
        `data` TEXT
    };
    my @items2 = split_create_table_items($body2);
    $assert->(scalar(@items2) == 3,
        "inline -- comment with commas: 3 items (got " . scalar(@items2) . ")");

    # Verifier que les colonnes attendues sont bien capturees (pas le commentaire)
    my $has_name = grep { /\`name\`\s+VARCHAR/ } @items2;
    $assert->($has_name, "name column survived after inline comment");

    # -------------------------------------------------------------------------
    # Test 3: '-- ...' inside a string MUST be preserved
    # -------------------------------------------------------------------------
    my $body3 = q{
        `a` INT,
        `b` VARCHAR(50) DEFAULT "this -- stays",
        `c` INT
    };
    my @items3 = split_create_table_items($body3);
    $assert->(scalar(@items3) == 3,
        "-- inside string: 3 items (got " . scalar(@items3) . ")");
    my $b_kept = grep { /this -- stays/ } @items3;
    $assert->($b_kept, "string content with -- preserved verbatim");

    # -------------------------------------------------------------------------
    # Test 3b: MySQL inline # comments must also be skipped outside strings
    # -------------------------------------------------------------------------
    my $body3b = q{
        `id` INT, # a comment with, commas, inside
        `name` VARCHAR(64),
        `hashy` VARCHAR(50) DEFAULT "this # stays"
    };
    my @items3b = split_create_table_items($body3b);
    $assert->(scalar(@items3b) == 3,
        "inline # comment with commas: 3 items (got " . scalar(@items3b) . ")");
    my $hashy_kept = grep { /this # stays/ } @items3b;
    $assert->($hashy_kept, "string content with # preserved verbatim");

    # -------------------------------------------------------------------------
    # Test 4: ENUM avec virgules dans une string, DECIMAL(10,2), JSON_OBJECT
    # -------------------------------------------------------------------------
    my $body4 = q{
        `id` INT,
        `state` ENUM("active","inactive","pending") DEFAULT "active",
        `price` DECIMAL(10,2) NOT NULL DEFAULT 0.00,
        PRIMARY KEY (`id`)
    };
    my @items4 = split_create_table_items($body4);
    $assert->(scalar(@items4) == 4,
        "strings + DECIMAL parens: 4 items (got " . scalar(@items4) . ")");

    # -------------------------------------------------------------------------
    # Test 5: garde-fou des mots reserves
    # -------------------------------------------------------------------------
    $assert->(is_reserved_or_attribute_identifier('COMMENT') == 1,
        "COMMENT is reserved");
    $assert->(is_reserved_or_attribute_identifier('DEFAULT') == 1,
        "DEFAULT is reserved");
    $assert->(is_reserved_or_attribute_identifier('KEY') == 1,
        "KEY is reserved");
    $assert->(is_reserved_or_attribute_identifier('id_user') == 0,
        "id_user is NOT reserved");
    $assert->(is_reserved_or_attribute_identifier('nick') == 0,
        "nick is NOT reserved");

    # -------------------------------------------------------------------------
    # Test 6: detection de contraintes
    # -------------------------------------------------------------------------
    $assert->(is_table_constraint('PRIMARY KEY (`id`)') == 1,
        "PRIMARY KEY detected");
    $assert->(is_table_constraint('  UNIQUE KEY foo (col)') == 1,
        "UNIQUE KEY detected (leading whitespace)");
    $assert->(is_table_constraint('CONSTRAINT fk_x FOREIGN KEY (id)') == 1,
        "CONSTRAINT detected");
    $assert->(is_table_constraint('`id` INT NOT NULL') == 0,
        "regular column not detected as constraint");
};
