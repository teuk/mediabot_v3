# MB723-B — persistent sessions, central CSRF and bounded security logging.

use strict;
use warnings;
use utf8;

sub _slurp_1036 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "$path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    my $app = _slurp_1036('contrib/mbweb/app.js');
    my $config = _slurp_1036('contrib/mbweb/lib/configCore.js');
    my $csrf = _slurp_1036('contrib/mbweb/lib/csrf.js');
    my $throttle = _slurp_1036('contrib/mbweb/lib/loginThrottle.js');
    my $store = _slurp_1036('contrib/mbweb/lib/mysqlSessionStore.js');
    my $policy = _slurp_1036('contrib/mbweb/lib/sessionPolicy.js');
    my $lifecycle = _slurp_1036('contrib/mbweb/lib/sessionLifecycle.js');
    my $security_log = _slurp_1036('contrib/mbweb/lib/securityLog.js');
    my $auth = _slurp_1036('contrib/mbweb/routes/auth.js');
    my $diagnostics = _slurp_1036('contrib/mbweb/routes/diagnostics.js');
    my $render = _slurp_1036('contrib/mbweb/lib/render.js');
    my $migration = _slurp_1036('install/migrations/20260904_mbweb_sessions.sql');
    my $schema = _slurp_1036('install/mediabot.sql');
    my $contract = _slurp_1036('docs/MBWEB_3.5.md');
    my $roadmap = _slurp_1036('docs/ROADMAP_3.5.md');
    my $migration_doc = _slurp_1036('docs/DB_MIGRATIONS.md');
    my $readme = _slurp_1036('contrib/mbweb/README.md');

    $assert->like($config,
        qr/Production requires MBWEB_SESSION_STORE=mysql; MemoryStore is forbidden/,
        'mb723b: production refuses the default MemoryStore');
    $assert->like($config, qr/Production MBWEB_HOST must be an explicit loopback/,
        'mb723b: production bind stays explicitly loopback-only');
    $assert->like($config, qr/MBWEB_SESSION_MAX_AGE_MS.*8 \* 60 \* 60 \* 1000/s,
        'mb723b: session maximum age is explicit and bounded');
    $assert->like($config, qr/MBWEB_SESSION_CLEANUP_INTERVAL_MS.*5 \* 60 \* 1000/s,
        'mb723b: session cleanup interval is explicit and bounded');

    $assert->like($app, qr/createMySqlSessionStore/,
        'mb723b: application wires the persistent session store');
    $assert->like($app, qr/sessionStore\?\.assertReady/,
        'mb723b: persistent store readiness precedes listener acceptance');
    $assert->like($app, qr/for \(const closeable of \[sessionStore, poolImpl\]\)/,
        'mb723b: failed startup closes session and database resources');
    $assert->like($app, qr/app\.use\(createCsrfProtection\(\)\)/,
        'mb723b: one CSRF boundary precedes the route surface');
    $assert->like($app, qr/app\.set\('trust proxy', 'loopback'\)/,
        'mb723b: proxy trust remains loopback-only');
    $assert->like($app, qr/urlencoded\(\{ extended: false, limit: '32kb', parameterLimit: 64 \}\)/,
        'mb723b: form bodies and parameter counts are explicitly bounded');
    $assert->like($app, qr/json\(\{ limit: '32kb' \}\)/,
        'mb723b: JSON request bodies are explicitly bounded');

    $assert->like($policy, qr/httpOnly: true/,
        'mb723b: cookies remain HttpOnly');
    $assert->like($policy, qr/sameSite: 'lax'/,
        'mb723b: cookies retain explicit SameSite policy');
    $assert->like($policy, qr/secure: config\.nodeEnv === 'production'/,
        'mb723b: production cookies are Secure');
    $assert->like($policy, qr/maxAge: config\.session\.maxAgeMs/,
        'mb723b: cookie expiry matches server session policy');

    $assert->like($csrf, qr/SAFE_METHODS = new Set\(\['GET', 'HEAD', 'OPTIONS'\]\)/,
        'mb723b: all unsafe HTTP methods cross CSRF validation');
    $assert->like($csrf, qr/crypto\.timingSafeEqual/,
        'mb723b: token comparison is timing-safe');
    $assert->like($csrf, qr/req\?\.session\?\._csrf/,
        'mb723b: token is bound to the session');

    $assert->like($throttle, qr/this\.maxEntries = Number\(options\.maxEntries\) \|\| 2048/,
        'mb723b: login throttle has a fixed address capacity');
    $assert->like($throttle, qr/this\.entries\.size >= this\.maxEntries/,
        'mb723b: unseen sources fail closed at capacity');
    $assert->like($throttle, qr/timer\.unref\?\.\(\)/,
        'mb723b: throttle pruning cannot hold process shutdown');

    $assert->like($store, qr/RETRYABLE_CODES = new Set/,
        'mb723b: reconnect errors have an explicit allowlist');
    $assert->like($store, qr/attempt >= 1/,
        'mb723b: session-store reconnect is attempted at most once');
    $assert->like($store,
        qr/DELETE FROM \$\{table\} WHERE expires_at <= CURRENT_TIMESTAMP\(3\) LIMIT \$\{cleanupBatchSize\}/,
        'mb723b: expired sessions have bounded server-side cleanup');
    $assert->like($store, qr/SESSION_DATA_INVALID/,
        'mb723b: oversized or malformed session payloads fail closed');
    $assert->unlike($store, qr/MemoryStore|fallback/i,
        'mb723b: persistent store failure has no memory fallback');

    $assert->like($lifecycle, qr/req\.session\.regenerate/,
        'mb723b: successful authentication rotates the session');
    $assert->like($lifecycle, qr/ensureCsrfToken\(req\.session/,
        'mb723b: authentication rotation also rotates the CSRF boundary');
    $assert->like($auth, qr/router\.post\('\/logout', requireLogin/,
        'mb723b: logout is a protected POST');
    $assert->like($auth, qr/buildSessionUser\(result\.user, result\.levelCol, \{ strict: true \}\)/,
        'mb723b: login authorization fails closed when role loading fails');
    $assert->unlike($auth, qr/router\.get\('\/logout'/,
        'mb723b: no state-changing logout GET remains');
    $assert->like($render, qr/<form method="post" action="\$\{logoutUrl\}"/,
        'mb723b: navigation renders a POST logout form');

    $assert->unlike($diagnostics, qr/diagnostics\?refresh=1|req\.query\.refresh/,
        'mb723b: GET diagnostics no longer mutates cache state');
    $assert->like($diagnostics,
        qr/router\.post\('\/diagnostics\/cache\/clear', requireFreshLogin/,
        'mb723b: owner cache maintenance uses an intentional POST');
    $assert->like($diagnostics, qr/logAudit\(console, 'cache\.clear'/,
        'mb723b: cache clearing is auditable without private payloads');

    my $session_user = _slurp_1036('contrib/mbweb/lib/sessionUser.js');
    $assert->like($session_user,
        qr/refreshSessionUser\(req, \{ force: true, strict: true \}\)/,
        'mb723b: privileged maintenance refreshes authorization synchronously');
    $assert->like($session_user, qr/return res\.status\(503\)/,
        'mb723b: privileged maintenance fails closed if authorization cannot refresh');

    $assert->like($security_log, qr/errorDescriptor/,
        'mb723b: runtime errors are reduced to bounded descriptors');
    my @runtime_js = (
        glob('contrib/mbweb/lib/*.js'),
        glob('contrib/mbweb/routes/*.js'),
    );
    $assert->unlike(join("\n", map { _slurp_1036($_) } @runtime_js),
        qr/err\.message|req\.originalUrl/,
        'mb723b: logs and error pages cannot echo raw error or query text');

    for my $sql ($migration, $schema) {
        $assert->like($sql, qr/CREATE TABLE(?: IF NOT EXISTS)? `MBWEB_SESSION`/,
            'mb723b: canonical schema and migration define the session table');
        $assert->like($sql, qr/KEY `idx_mbweb_session_expires_at` \(`expires_at`\)/,
            'mb723b: canonical schema and migration index expiry cleanup');
    }
    $assert->unlike($migration, qr/^\s*(?:CREATE USER|GRANT)\b/im,
        'mb723b: migration grants no implicit database authority');
    $assert->like($migration_doc, qr/20260904_mbweb_sessions\.sql/,
        'mb723b: public migration inventory lists the session migration');

    $assert->like($contract, qr/\*\*Status: complete on the development source\.\*\* MB723-B/,
        'mb723b: detailed contract records the completed source gate');
    $assert->like($roadmap, qr/^\| MB723-B \| Complete on development source \|/m,
        'mb723b: roadmap records session and request hardening evidence');
    $assert->like($readme,
        qr/SELECT, INSERT, UPDATE and DELETE\s+only on\s+`MBWEB_SESSION`/,
        'mb723b: least-privileged session-table rights are documented');
};
