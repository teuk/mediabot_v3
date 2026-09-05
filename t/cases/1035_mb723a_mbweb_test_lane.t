# MB723-A — deterministic mbweb application lane and lifecycle boundaries.

use strict;
use warnings;
use utf8;

use JSON::PP qw(decode_json);

sub _slurp_1035 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "$path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    my $package = decode_json(_slurp_1035('contrib/mbweb/package.json'));
    my $app = _slurp_1035('contrib/mbweb/app.js');
    my $config = _slurp_1035('contrib/mbweb/lib/configCore.js');
    my $auth = _slurp_1035('contrib/mbweb/lib/authCore.js');
    my $session = _slurp_1035('contrib/mbweb/lib/sessionUserCore.js');
    my $sql = _slurp_1035('contrib/mbweb/lib/sql.js');
    my $repository = _slurp_1035('contrib/mbweb/lib/mediabotRepository.js');
    my $radio = _slurp_1035('contrib/mbweb/lib/radio.js');
    my $metrics = _slurp_1035('contrib/mbweb/lib/metrics.js');
    my $partyline = _slurp_1035('contrib/mbweb/lib/partylineRuntime.js');
    my $lifecycle = _slurp_1035('contrib/mbweb/lib/serverLifecycle.js');
    my $auth_route = _slurp_1035('contrib/mbweb/routes/auth.js');
    my $contract = _slurp_1035('docs/MBWEB_3.5.md');
    my $roadmap = _slurp_1035('docs/ROADMAP_3.5.md');
    my $readme = _slurp_1035('contrib/mbweb/README.md');

    $assert->is(
        $package->{scripts}{test},
        'node --test test/*.test.js',
        'mb723a: package exposes the deterministic built-in Node lane'
    );
    $assert->ok(!keys %{ $package->{devDependencies} || {} },
        'mb723a: application lane adds no test dependency');

    my @tests = sort glob('contrib/mbweb/test/*.test.js');
    my @mb723a = sort qw(
        contrib/mbweb/test/auth-session-permissions.test.js
        contrib/mbweb/test/config.test.js
        contrib/mbweb/test/http-lifecycle.test.js
        contrib/mbweb/test/request-repository.test.js
        contrib/mbweb/test/upstreams.test.js
    );
    my %tests = map { $_ => 1 } @tests;
    $assert->ok(!(grep { !$tests{$_} } @mb723a),
        'mb723a: all five baseline Node files remain in the growing lane');

    my $tests = join("\n", map { _slurp_1035($_) } @tests);
    for my $needle (
        'buildConfig', 'validateSessionSecret', 'verifyPassword',
        'normalizeSessionUser', q{can(owner, 'view:system')},
        'parsePositiveInt', 'qIdent', 'getUserById',
        'Malformed database result', 'createHttpBoundaries',
        'fetchJson', 'fetchMetrics', 'readPartylineRuntime',
        'listenHttpServer', 'installGracefulShutdown'
    ) {
        $assert->like($tests, qr/\Q$needle\E/,
            "mb723a: Node tests cover $needle");
    }

    $assert->like($config, qr/class ConfigError extends Error/,
        'mb723a: configuration failures are testable exceptions');
    $assert->like($config, qr/function buildConfig\(env = process\.env\)/,
        'mb723a: configuration consumes an explicit environment');
    $assert->like($auth, qr/options\.bcryptCompare/,
        'mb723a: bcrypt comparison has a bounded adapter seam');
    $assert->like($session, qr/function normalizeSessionUser/,
        'mb723a: session normalization is a pure shared policy');
    $assert->like($sql, qr/^\s*if \(!\/\^\[A-Za-z0-9_\]\+\$\/\.test\(identifier\)\)/m,
        'mb723a: dynamic identifiers remain allowlisted');
    $assert->like($repository, qr/Malformed database result for \$\{operation\}/,
        'mb723a: malformed driver results fail closed');

    for my $source ($radio, $metrics) {
        $assert->like($source, qr/options\.fetchImpl \|\| globalThis\.fetch/,
            'mb723a: HTTP upstream uses an injectable fetch boundary');
        $assert->like($source, qr/Buffer\.byteLength\(text, 'utf8'\)/,
            'mb723a: HTTP upstream enforces byte size rather than characters');
    }
    $assert->like($partyline, qr/options\.fsImpl \|\| fs/,
        'mb723a: Partyline input uses an injectable file boundary');
    $assert->like($partyline, qr/DEFAULT_MAX_SESSIONS = 100/,
        'mb723a: Partyline input retains a hard session ceiling');

    $assert->like($app, qr/function createApp\(options = \{\}\)/,
        'mb723a: Express construction is separate from startup');
    $assert->like($app, qr/if \(require\.main === module\)/,
        'mb723a: importing the app no longer opens a listener');
    $assert->like($app, qr/installGracefulShutdown/,
        'mb723a: normal runtime installs the tested shutdown boundary');
    $assert->like($lifecycle, qr/server\.once\('error', onError\)/,
        'mb723a: listener startup failure rejects deterministically');
    $assert->like($lifecycle, qr/server\.close\(finish\)/,
        'mb723a: graceful shutdown closes the listener');
    $assert->like($auth_route, qr/loginThrottle\.startPruning\(\)/,
        'mb723a: login housekeeping cannot hold shutdown open');

    $assert->unlike($tests, qr/\brequire\(['"](?:express|mysql2|dotenv|bcryptjs)/,
        'mb723a: deterministic tests do not require installed application dependencies');
    $assert->unlike($tests, qr/\b(?:fetch|connect|createConnection)\s*\(\s*['"]https?:/,
        'mb723a: deterministic tests make no real network connection');
    $assert->unlike($tests, qr/(?:mediabot\.conf|MBWEB_DB_PASS|MBWEB_SESSION_SECRET\s*=)/,
        'mb723a: deterministic tests read no live configuration or secret');

    $assert->like($contract,
        qr/\*\*Status: complete on the development source\.\*\* `npm test` runs 23 focused/,
        'mb723a: detailed contract records the completed Node lane');
    $assert->like($contract, qr/^## MB723-A — deterministic application evidence/m,
        'mb723a: its evidence remains independently documented');
    $assert->like($roadmap, qr/^\| MB723-A \| Complete on development source \|/m,
        'mb723a: roadmap records deterministic evidence');
    $assert->like($readme, qr/`npm test` is the deterministic (?:MB723-A |MB723 )?application lane/,
        'mb723a: operator documentation exposes the Node lane');
};
