# MB719 source prerequisite — quote input and storage share one exact limit.

use strict;
use warnings;
use utf8;

sub _slurp_1040 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "$path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    my $quotes = _slurp_1040('Mediabot/Quotes.pm');
    my $schema = _slurp_1040('install/mediabot.sql');
    my $migration = _slurp_1040(
        'install/migrations/20260905_quotes_512_contract.sql'
    );
    my $migration_doc = _slurp_1040('install/migrations/README.md');
    my $db_doc = _slurp_1040('docs/DB_MIGRATIONS.md');
    my $roadmap = _slurp_1040('docs/ROADMAP_3.5.md');
    my $changelog = _slurp_1040('CHANGELOG.md');

    $assert->like($quotes, qr/length\(\$sQuoteText\)\s*>\s*512/,
        'mb719: application rejects quote text above 512 characters');
    $assert->like($quotes, qr/Quote text too long \(max 512 chars\)/,
        'mb719: operator feedback exposes the same quote limit');

    my ($quote_table) = $schema =~
        /(CREATE TABLE `QUOTES` \(.*?\n\) ENGINE=InnoDB)/s;
    $assert->ok(defined $quote_table && $quote_table ne '',
        'mb719: fresh QUOTES schema is present');
    $assert->like($quote_table,
        qr/`quotetext`\s+VARCHAR\(512\) NOT NULL/,
        'mb719: fresh schema stores the full accepted quote');
    $assert->unlike($quote_table, qr/`quotetext`\s+VARCHAR\(255\)/,
        'mb719: obsolete 255-character storage contract is absent');

    $assert->like($migration,
        qr/CREATE PROCEDURE `mb719_align_quotes_512`\(\)/,
        'mb719: upgrade uses a bounded replayable procedure');
    $assert->like($migration,
        qr/`TABLE_NAME`\s*=\s*'QUOTES'.*?`TABLE_TYPE`\s*=\s*'BASE TABLE'/s,
        'mb719: upgrade requires the expected base table');
    $assert->like($migration,
        qr/v_data_type\s*<>\s*'varchar'/,
        'mb719: upgrade rejects an unexpected storage type');
    $assert->like($migration,
        qr/v_capacity\s*>\s*512.*?refusing to narrow/s,
        'mb719: upgrade never narrows a wider local column');
    $assert->like($migration,
        qr/CHAR_LENGTH\(`quotetext`\)\s*>\s*512/,
        'mb719: upgrade guards the application length boundary');
    $assert->like($migration,
        qr/MODIFY COLUMN `quotetext` VARCHAR\(512\) NOT NULL/,
        'mb719: upgrade converges on the canonical definition');
    $assert->like($migration,
        qr/CALL `mb719_align_quotes_512`\(\);.*?DROP PROCEDURE `mb719_align_quotes_512`;/s,
        'mb719: upgrade executes and removes its temporary helper');
    $assert->unlike($migration,
        qr/\b(?:DELETE\s+FROM|UPDATE\s+`?QUOTES`?|TRUNCATE\s+TABLE|DROP\s+TABLE)\b/i,
        'mb719: upgrade never mutates or removes quote rows');

    for my $doc ($migration_doc, $db_doc) {
        $assert->like($doc, qr/20260905_quotes_512_contract\.sql/,
            'mb719: ordered migration documentation includes quote alignment');
        $assert->like($doc, qr/512(?:-character| characters)/i,
            'mb719: migration documentation names the application contract');
    }

    $assert->like($changelog,
        qr/^### mb719 source prerequisite — align the quote storage contract$/m,
        'mb719: changelog records the bounded source correction');
    $assert->like($roadmap, qr/^\| MB719 \| P0 \|/m,
        'mb719: production reconciliation remains explicitly open');
};
