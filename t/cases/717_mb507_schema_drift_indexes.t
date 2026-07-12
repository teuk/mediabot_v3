use strict;
use warnings;
use FindBin qw($Bin);
use File::Spec;
use File::Temp qw(tempfile);

my $script = File::Spec->catfile($Bin, '..', '..', 'tools', 'check_schema_drift.pl');

return sub {
    my ($assert) = @_;
    open my $fh, '<', $script or do { $assert->(0, "Cannot open $script: $!"); return; };
    my $code = do { local $/; <$fh> };
    close $fh;

    my @subs = qw(defined_non_empty split_create_table_items is_table_constraint
        is_reserved_or_attribute_identifier normalize_create_table parse_index_item
        normalize_index_signature compare_required_indexes render_add_index_sql parse_schema_file);
    my $loaded = 0;
    for my $name (@subs) {
        if ($code =~ /(sub $name.*?^}\n)/sm) {
            eval $1;
            if ($@) { $assert->(0, "load $name: $@"); return; }
            $loaded++;
        }
    }
    $assert->($loaded == scalar(@subs), 'loaded index drift helpers');

    my ($tfh, $tmp) = tempfile('idx_XXXX', SUFFIX => '.sql', UNLINK => 1);
    print {$tfh} <<'SQL';
CREATE TABLE `QUOTES` (
 `id_quotes` BIGINT NOT NULL,
 `id_channel` BIGINT NOT NULL,
 `hits` BIGINT NOT NULL DEFAULT 0,
 PRIMARY KEY (`id_quotes`),
 KEY `idx_quotes_channel_hits` (`id_channel`, `hits`),
 UNIQUE KEY `uniq_demo` (`id_channel`, `id_quotes`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
SQL
    close $tfh;
    my $ref = parse_schema_file($tmp);
    $assert->(exists $ref->{QUOTES}{indexes}{primary}, 'PRIMARY parsed');
    $assert->(exists $ref->{QUOTES}{indexes}{idx_quotes_channel_hits}, 'composite index parsed');
    $assert->(normalize_index_signature($ref->{QUOTES}{indexes}{idx_quotes_channel_hits}) eq 'nonunique|id_channel,hits', 'signature correct');

    my @issues;
    compare_required_indexes($ref->{QUOTES}{indexes}, { primary => $ref->{QUOTES}{indexes}{primary} }, 'QUOTES', \@issues);
    $assert->(scalar(grep { $_->{kind} eq 'missing_index' && $_->{index} eq 'idx_quotes_channel_hits' } @issues) == 1, 'missing index detected');

    my $wrong = { %{ $ref->{QUOTES}{indexes} } };
    $wrong->{idx_quotes_channel_hits} = { name=>'idx_quotes_channel_hits', unique=>0, columns=>[{name=>'hits',order=>''},{name=>'id_channel',order=>''}] };
    my @wrong;
    compare_required_indexes($ref->{QUOTES}{indexes}, $wrong, 'QUOTES', \@wrong);
    $assert->(scalar(grep { $_->{kind} eq 'index_drift' } @wrong) == 1, 'wrong order detected');

    my $sql = render_add_index_sql('QUOTES', $ref->{QUOTES}{indexes}{idx_quotes_channel_hits});
    $assert->($sql eq 'ALTER TABLE `QUOTES` ADD INDEX `idx_quotes_channel_hits` (`id_channel`, `hits`);', 'safe ADD INDEX generated');
    $assert->(!defined render_add_index_sql('QUOTES', $ref->{QUOTES}{indexes}{primary}), 'PRIMARY never auto-generated');
    $assert->($code =~ /'indexes'\s*=>\s*\\\$opt\{indexes\}/, '--indexes wired');
    $assert->($code =~ /No DROP\/REPLACE generated/, 'mismatch stays non-destructive');
};
