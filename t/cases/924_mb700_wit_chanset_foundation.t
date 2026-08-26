# t/cases/924_mb700_wit_chanset_foundation.t
# =============================================================================
# MB700-B — register +Wit as a default-off channel capability.
#
# This round is data/schema plumbing only. Fresh installs and upgraded DBs
# must know the same chanset, while no CHANNEL_SET row is created automatically
# and no runtime module may consume +Wit yet.
# =============================================================================

use strict;
use warnings;
use utf8;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Find qw(find);

sub _slurp_924 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "$path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    my $schema = _slurp_924('install/mediabot.sql');
    my $mig    = _slurp_924('install/migrations/20260825_wit_chanset.sql');
    my $mread  = _slurp_924('install/migrations/README.md');
    my $dbdoc  = _slurp_924('docs/DB_MIGRATIONS.md');
    my $cl     = _slurp_924('CHANGELOG.md');

    $assert->like(
        $schema,
        qr/\(24,\s*'Wit'\);/,
        'mb700-924: fresh schema registers canonical Wit chanset',
    );

    my @fresh_wit = ($schema =~ /^\(\d+,\s*'Wit'\)[,;]/mg);
    $assert->is(
        scalar(@fresh_wit), 1,
        'mb700-924: fresh schema contains exactly one Wit reference row',
    );

    $assert->like(
        $mig,
        qr/INSERT INTO CHANSET_LIST \(chanset\)\s+SELECT 'Wit'\s+WHERE NOT EXISTS\s*\(\s*SELECT 1 FROM CHANSET_LIST WHERE chanset = 'Wit'/s,
        'mb700-924: upgrade migration adds Wit idempotently by name',
    );

    $assert->unlike(
        $mig,
        qr/\b(?:INSERT|REPLACE|UPDATE|DELETE)\b[^;]*\bCHANNEL_SET\b/is,
        'mb700-924: migration never enables Wit on an existing channel',
    );

    $assert->unlike(
        $mig,
        qr/\b(?:CREATE|ALTER|DROP|RENAME|TRUNCATE)\b/i,
        'mb700-924: Wit migration is data-only and performs no DDL',
    );

    $assert->like(
        $mig,
        qr/SET NAMES utf8mb4;/,
        'mb700-924: migration keeps explicit utf8mb4 client semantics',
    );

    $assert->like(
        $mread,
        qr/^20260825_wit_chanset\.sql$/m,
        'mb700-924: authoritative migration inventory lists Wit migration',
    );

    $assert->like(
        $dbdoc,
        qr/^20260825_wit_chanset\.sql$/m,
        'mb700-924: DB migration guide lists Wit migration',
    );

    $assert->like(
        $dbdoc,
        qr{SOURCE /home/mediabot/mediabot_v3/install/migrations/20260825_wit_chanset\.sql;},
        'mb700-924: manual migration example includes Wit migration',
    );

    $assert->like(
        $cl,
        qr/Wit.*?default|default-off|opted out/is,
        'mb700-924: changelog records default-off Wit semantics',
    );

    my @runtime_pm;
    find(
        sub {
            return unless -f $_ && /\.pm\z/;
            my $path = $File::Find::name;
            return if $path =~ m{^\./?t/};
            push @runtime_pm, $path;
        },
        'Mediabot',
    );

    my @consumers;
    for my $path (@runtime_pm) {
        my $src = _slurp_924($path);
        push @consumers, $path
            if $src =~ /(?:chanset_enabled|_chanset_ok|getIdChansetList)\s*\([^\n]*['"]Wit['"]/;
    }

    $assert->is(
        scalar(@consumers), 0,
        'mb700-924: no runtime module consumes +Wit yet',
    );

    my $policy = _slurp_924('Mediabot/AI/ConversationPolicy.pm');
    $assert->unlike(
        $policy,
        qr/\b(?:CHANNEL_SET|CHANSET_LIST|dbh|DBI)\b/,
        'mb700-924: ConversationPolicy remains independent from DB/chanset storage',
    );
};
