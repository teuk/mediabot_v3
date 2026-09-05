# MB723-C — read-only capability surface and bounded development pilot.

use strict;
use warnings;
use utf8;

sub _slurp_1037 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "$path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    my $catalog = _slurp_1037('contrib/mbweb/lib/channelCapabilities.js');
    my $repo = _slurp_1037('contrib/mbweb/lib/mediabotRepository.js');
    my $routes = _slurp_1037('contrib/mbweb/routes/channels.js');
    my $node_test = _slurp_1037('contrib/mbweb/test/channel-capabilities.test.js');
    my $contract = _slurp_1037('docs/MBWEB_3.5.md');
    my $roadmap = _slurp_1037('docs/ROADMAP_3.5.md');
    my $readme = _slurp_1037('contrib/mbweb/README.md');

    for my $name (qw(Hailo Gemini Spark Fullop)) {
        $assert->like($catalog, qr/\Q$name\E/,
            "mb723c: accepted capability $name is explicit");
    }
    for my $name (qw(HailoLearn HailoRespond HailoChatter SparkAction)) {
        $assert->like($catalog, qr/\Q$name\E/,
            "mb723c: accepted sub-capability $name is explicit");
    }

    $assert->like($catalog, qr/state: available \? \(enabled \? 'enabled' : 'disabled'\) : 'unavailable'/,
        'mb723c: capability state is three-valued and fail-closed');
    $assert->like($repo, qr/async function getChannelCapabilities\(idChannel\)/,
        'mb723c: repository exposes one capability lookup');
    $assert->like($repo, qr/FROM CHANSET_LIST cl.*LEFT JOIN CHANNEL_SET cs/s,
        'mb723c: capability lookup uses canonical chanset tables');
    $assert->like($repo, qr/cs\.id_channel = \?/,
        'mb723c: capability lookup parameterizes channel identity');
    $assert->like($repo, qr/cl\.chanset IN \(\$\{placeholders\}\)/,
        'mb723c: capability lookup is restricted to the fixed catalogue');
    $assert->unlike($repo, qr/(?:INSERT|UPDATE|DELETE)\s+(?:INTO|FROM)?\s*(?:CHANSET_LIST|CHANNEL_SET)/i,
        'mb723c: repository never mutates channel capability tables');

    $assert->like($routes, qr/getChannelCapabilities\(idChannel\)/,
        'mb723c: channel HTML and API load capability state');
    $assert->like($routes, qr/Accepted 3\.5 capabilities/,
        'mb723c: HTML names the accepted capability boundary');
    $assert->like($routes, qr/res\.json\(\{ ok: true, channel, users, capabilities, relatedTables \}\)/,
        'mb723c: JSON includes the same capability state');
    $assert->unlike($routes, qr/router\.(?:post|put|patch|delete)\([^\n]*channels/i,
        'mb723c: channel route surface stays read-only');

    $assert->like($node_test, qr/missing capability metadata is reported as unavailable/,
        'mb723c: Node lane covers unavailable metadata');
    $assert->like($contract, qr/\*\*Status: complete on the development pilot\.\*\*/,
        'mb723c: detailed contract records the accepted pilot');
    $assert->like($contract, qr/No Mediabot IRC service was restarted/,
        'mb723c: IRC runtime independence is explicit');
    $assert->like($roadmap, qr/^\| MB723-C \| Complete on development pilot \|/m,
        'mb723c: roadmap records live route evidence');
    $assert->like($roadmap, qr/^\| MB723-D \| Complete on development deployment \|/m,
        'mb723c: later operational promotion preserves the accepted pilot evidence');
    $assert->like($readme, qr/query reads `CHANSET_LIST` and `CHANNEL_SET` with a fixed\s+allowlist/s,
        'mb723c: public operation documents the read-only query boundary');
};
