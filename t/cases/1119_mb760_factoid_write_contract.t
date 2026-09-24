# MB760 — machine and documentation contracts seal factoid write authority.

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib", "$Bin/../..";
}

use JSON::PP ();

sub slurp_1119 {
    my ($path) = @_;
    open my $fh, '<:raw', $path or die "$path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;
    my $contract = JSON::PP->new->decode(
        slurp_1119('plugins/API_V3_CONTRACT.json'));
    $assert->is($contract->{milestone}, 'MB781',
        'machine contract records the current platform milestone');
    $assert->ok(grep($_ eq 'data.factoids.write',
        @{ $contract->{implemented_capabilities} }),
        'factoid writes use a capability distinct from reads');
    $assert->is(join(',', @{ $contract->{factoid_write_limits}{operations} }),
        'upsert,delete,recall',
        'only the three approved factoid mutations are exposed');
    $assert->is($contract->{factoid_write_limits}{activation}, 'on only',
        'observe can never mutate factoid data');
    $assert->is($contract->{factoid_write_limits}{plugin_adoption},
        'factoids-v3 learn, forget and whatis recall accounting, inactive by default',
        'write adoption remains explicit and operator-controlled');
    $assert->is($contract->{factoid_write_limits}{channel_source},
        'core invocation policy', 'plugin cannot select a write channel');
    $assert->is($contract->{factoid_write_limits}{principal_source},
        'core command context', 'plugin cannot supply its authorization');
    $assert->is($contract->{factoid_write_limits}{actor_nick_source},
        'core command invocation', 'plugin cannot forge display attribution');
    $assert->is($contract->{factoid_write_limits}{invocation_origin},
        'opaque runtime authority required',
        'plugin-created invocation lookalikes cannot reach writes');
    $assert->is($contract->{factoid_write_limits}{recall_counter_writes},
        'on-only exact channel and keyword increment',
        'recall mutation remains bounded after adopting whatis');

    my $read = slurp_1119('Mediabot/Plugin/FactoidServiceV3.pm');
    my $write = slurp_1119('Mediabot/Plugin/FactoidWriteServiceV3.pm');
    $assert->unlike($read, qr/\b(?:INSERT|UPDATE|DELETE)\b/i,
        'factoid read facade remains physically read-only');
    $assert->like($write, qr/INSERT INTO FACTOID/,
        'upsert SQL lives only in the dedicated service');
    $assert->like($write, qr/DELETE FROM FACTOID/,
        'delete uses the dedicated authorized service');
    $assert->like($write, qr/SET f\.hits = COALESCE\(f\.hits, 0\) \+ 1/,
        'recall uses one explicit null-safe counter increment');
    $assert->like($write, qr/created_by AS author_id/,
        'delete authorization uses numeric stored identity');
    $assert->unlike($write, qr/created_by_nick\s*=|lc\([^\n]*nick/,
        'nickname text is not a deletion authority');
    $assert->unlike($write, qr/\b(?:DROP|ALTER|CREATE)\b/i,
        'write facade has no schema administration');

    my $manifest = JSON::PP->new->decode(
        slurp_1119('plugins/factoids-v3/plugin.json'));
    $assert->ok(grep($_ eq 'data.factoids.write',
        @{ $manifest->{capabilities} }),
        'official factoid package requests the reviewed write authority');
    $assert->ok(exists($manifest->{commands}{learn})
        && exists($manifest->{commands}{forget})
        && exists($manifest->{commands}{whatis}),
        'learn, forget and recall now share reviewed write authority');

    my $api = slurp_1119('docs/PLUGIN_API_V3.md');
    $assert->like($api, qr/## Authorized factoid writes/,
        'author guide documents the separate write boundary');
    $assert->like($api, qr/MB761 grants `data\.factoids\.write`/,
        'author guide records the separately reviewed adoption');
};
