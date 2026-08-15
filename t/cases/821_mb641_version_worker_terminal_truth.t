# t/cases/821_mb641_version_worker_terminal_truth.t
# =============================================================================
# mb641 — garde pre-commit : getVersion_async ne doit JAMAIS rendre
# (local, Undefined) sans une raison quand son worker lui-meme a echoue.
# =============================================================================

use strict;
use warnings;
use utf8;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }

sub _slurp_821 {
    my ($p) = @_;
    open my $fh, '<:encoding(UTF-8)', $p or die "$p: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;
    my $src = _slurp_821('Mediabot/Helpers.pm');

    my ($async) = $src =~ /(sub getVersion_async \{.*?\n\}\n# getDetailedVersion)/s;
    $assert->ok(defined $async, 'mb641-821: getVersion_async localisee');

    # open/fork impossible : 3e argument obligatoire, jamais le vieux callback
    # silencieux a deux arguments.
    $assert->like($async,
        qr/version check worker could not start:/,
        'mb641-821: creation worker impossible => raison explicite');
    $assert->like($async,
        qr/\$callback->\(\$local, 'Undefined', \$reason\)/,
        'mb641-821: echec de creation transmet la raison au callback');
    $assert->unlike($async,
        qr/\$callback->\(\$fallback_local, 'Undefined'\)/,
        'mb641-821: ancien callback silencieux supprime');

    # Toutes les terminaisons du parent doivent etre distinguees.
    $assert->like($async, qr/version check timed out/,
        'mb641-821: timeout garde sa raison');
    $assert->like($async, qr/version check worker could not be reaped/,
        'mb641-821: waitpid impossible => raison');
    $assert->like($async, qr/version check worker terminated by signal \$signal/,
        'mb641-821: signal => raison');
    $assert->like($async, qr/version check worker exited with status \$exit/,
        'mb641-821: exit non-zero => raison');
    $assert->like($async, qr/version check worker produced no result/,
        'mb641-821: payload vide => raison');
    $assert->like($async, qr/version check worker returned an invalid result/,
        'mb641-821: payload non vide illisible => raison');

    # Le fallback local suit le meme contrat que les autres chemins.
    $assert->like($async,
        qr/_usable_local_version\(\$fallback_local\) \/\/ 'Undefined'/,
        'mb641-821: fallback local normalise');

    # Un payload JSON valide conserve toujours la raison produite par le fils.
    $assert->like($async,
        qr/\$reason = \$why if defined \$why && !ref \$why && length \$why/,
        'mb641-821: raison enfant valide preservee');
};
