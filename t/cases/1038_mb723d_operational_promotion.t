# MB723-D — reproducible mbweb deployment, hardening and rollback contract.

use strict;
use warnings;
use utf8;

sub _slurp_1038 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "$path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    my $deploy = _slurp_1038('install/mbweb_deploy.sh');
    my $unit = _slurp_1038('install/systemd/mbweb.service');
    my $apache = _slurp_1038('install/apache/mbweb.conf.example');
    my $contract = _slurp_1038('docs/MBWEB_3.5.md');
    my $roadmap = _slurp_1038('docs/ROADMAP_3.5.md');
    my $readme = _slurp_1038('contrib/mbweb/README.md');

    $assert->like($deploy, qr/npm .* ci --omit=dev --ignore-scripts --no-audit --no-fund/,
        'mb723d: runtime dependencies come from npm ci and the committed lock');
    $assert->like($deploy, qr/npm .* audit --omit=dev --audit-level=high --json/,
        'mb723d: dependency audit is recorded and rejects high severity findings');
    $assert->like($deploy, qr/--exclude='\.env'.*--exclude='\.env\.\*'.*--exclude='node_modules\/'/s,
        'mb723d: canonical synchronization excludes secrets and generated dependencies');
    $assert->like($deploy, qr/flock -n 9/,
        'mb723d: concurrent deployment is refused');
    $assert->like($deploy, qr/rsync -a --delete .*runtime\/.*APP_DIR/s,
        'mb723d: rollback restores the private runtime backup');
    $assert->like($deploy, qr/systemctl (?:start|stop) "\$SERVICE"/,
        'mb723d: lifecycle changes are limited to the selected web service');
    $assert->unlike($deploy, qr/mediabot\@[^'"\s]*\.service/,
        'mb723d: no IRC service is targeted');
    $assert->like($deploy, qr/health URL must be an explicit loopback \/health endpoint/,
        'mb723d: deployment health is pinned to loopback');
    $assert->like($deploy, qr/automatic rollback failed/,
        'mb723d: failed activation arms automatic rollback');

    for my $line (
        'User=mediabot',
        'Group=mediabot',
        'ProtectSystem=strict',
        'ProtectHome=read-only',
        'NoNewPrivileges=true',
        'PrivateTmp=true',
        'ReadOnlyPaths=/opt/mbweb/app',
        'StartLimitIntervalSec=60',
        'StartLimitBurst=5',
    ) {
        $assert->like($unit, qr/^\Q$line\E$/m, "mb723d: unit contains $line");
    }
    $assert->unlike($unit, qr/^ReadWritePaths=/m,
        'mb723d: web service has no persistent writable filesystem path');

    $assert->like($apache, qr/^ProxyPass\s+\/mediabotv3\/\s+http:\/\/127\.0\.0\.1:4002\/mediabotv3\//m,
        'mb723d: reverse proxy stays on loopback and preserves base path');
    $assert->like($apache, qr/X-Forwarded-Proto "https"/,
        'mb723d: secure-cookie proxy header is explicit');
    $assert->like($apache, qr/X-Forwarded-Prefix "\/mediabotv3"/,
        'mb723d: forwarded base path is explicit');

    $assert->like($contract, qr/\*\*Status: supported after operational promotion\.\*\*/,
        'mb723d: detailed contract records one explicit supported outcome');
    $assert->like($roadmap, qr/^\| MB723-D \| Complete on development deployment \|/m,
        'mb723d: roadmap records operational evidence');
    $assert->like($roadmap, qr/^\| MB723 \| Complete — supported \|/m,
        'mb723d: umbrella gate is explicitly closed as supported');
    $assert->like($readme, qr/sudo install\/mbweb_deploy\.sh deploy/,
        'mb723d: public runbook exposes the canonical deployment command');
    $assert->like($readme, qr/sudo install\/mbweb_deploy\.sh rollback/,
        'mb723d: public runbook exposes the bounded rollback command');
};
