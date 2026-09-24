# MB755 — anonymous quote authors use a nullable canonical identity.

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib", "$Bin/../..";
}

use JSON::PP ();

sub slurp_1108 {
    my ($path) = @_;
    open my $fh, '<:raw', $path or die "$path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    my $legacy = slurp_1108('Mediabot/Quotes.pm');
    my $write = slurp_1108('Mediabot/Plugin/QuoteWriteServiceV3.pm');
    my $schema = slurp_1108('install/mediabot.sql');
    my $migration = slurp_1108(
        'install/migrations/20260921_quotes_anonymous_author.sql');

    $assert->like($legacy,
        qr/my \$id_user\s*=.*?\?\s*\$iMatchingUserId\s*:\s*undef;/s,
        'saved quote handler binds NULL for an anonymous author');
    $assert->unlike($legacy,
        qr/my \$id_user\s*=.*?\?\s*\$iMatchingUserId\s*:\s*0;/s,
        'saved quote handler no longer invents USER id zero');
    $assert->ok(index($write,
        'my $author_id = $principal->authenticated ? $principal->user_id : undef;') >= 0,
        'v3 write service binds the same anonymous NULL identity');

    $assert->like($schema,
        qr/CREATE TABLE `QUOTES`.*?`id_user`\s+BIGINT UNSIGNED DEFAULT NULL/s,
        'fresh schema permits anonymous quote attribution');
    $assert->like($schema,
        qr/CONSTRAINT `fk_quotes_user`.*?ON DELETE SET NULL ON UPDATE CASCADE/s,
        'fresh schema preserves quotes when an author account is removed');

    $assert->like($migration,
        qr/CREATE PROCEDURE `mb755_align_quote_author`/,
        'upgrade is packaged as a replayable convergence procedure');
    $assert->like($migration,
        qr/MODIFY COLUMN `id_user` BIGINT UNSIGNED NULL DEFAULT NULL/,
        'upgrade makes the deployed attribution column nullable');
    $assert->like($migration,
        qr/SET q\.`id_user` = NULL.*?q\.`id_user` = 0 OR u\.`id_user` IS NULL/s,
        'upgrade repairs both zero and orphan attribution');
    $assert->like($migration,
        qr/FOREIGN\s+KEY\s+\(`id_user`\).*?REFERENCES\s+`USER`.*?
           ON\s+DELETE\s+SET\s+NULL\s+ON\s+UPDATE\s+CASCADE/sx,
        'upgrade installs the canonical preserving foreign key');
    $assert->unlike($migration, qr/DELETE\s+FROM\s+`?QUOTES`?/i,
        'upgrade never deletes quote rows');
    $assert->like($migration,
        qr/IS_NULLABLE`?\s*=\s*'YES'/,
        'upgrade verifies the final nullable column contract');
    $assert->like($migration,
        qr/DELETE_RULE`?\s*=\s*'SET NULL'/,
        'upgrade verifies the final foreign-key delete rule');

    my $contract = JSON::PP->new->decode(
        slurp_1108('plugins/API_V3_CONTRACT.json'));
    $assert->is($contract->{milestone}, 'MB772',
        'machine contract records the current platform milestone');
    $assert->is($contract->{quote_write_limits}{add_attribution},
        'authenticated user id or SQL NULL for anonymous',
        'machine contract exposes no fake anonymous user id');

    my $manifest = JSON::PP->new->decode(
        slurp_1108('plugins/quotes-v3/plugin.json'));
    $assert->is($manifest->{version}, '1.1.1',
        'official quote package version records the repair');

    for my $path ('install/migrations/README.md', 'docs/DB_MIGRATIONS.md') {
        $assert->like(slurp_1108($path),
            qr/20260921_quotes_anonymous_author\.sql/,
            "$path lists the required migration");
    }
    my $pilot = slurp_1108('docs/QUOTE_COMMAND_V3_PILOT.md');
    $assert->like($pilot,
        qr/Database error while adding quote.*?stop before/s,
        'pilot fails closed before promotion after an anonymous write error');
    $assert->like($pilot,
        qr/anonymous quote authors use nullable attribution/,
        'pilot states the repaired attribution contract');
};
