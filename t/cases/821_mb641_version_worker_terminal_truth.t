# t/cases/821_mb641_version_worker_terminal_truth.t
# =============================================================================
# mb641/mb652 — getVersion_async must never turn a terminal worker failure
# into silent "(local, Undefined)". MB652 preserves that operator-facing
# contract while delegating lifecycle mechanics to Mediabot::AsyncWorker.
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
    my ($reason) = $src =~ /(sub _version_asyncworker_reason \{.*?\n\}\n\nsub getVersion_async)/s;

    $assert->ok(defined $async, 'mb652-821: getVersion_async localisee');
    $assert->ok(defined $reason, 'mb652-821: mapping terminal AsyncWorker localise');

    $assert->like($async // '',
        qr/Mediabot::AsyncWorker->start\(/,
        'mb652-821: version checker delegates lifecycle to AsyncWorker');

    $assert->like($reason // '', qr/version check timed out/,
        'mb641-821: timeout garde sa raison');
    $assert->like($reason // '', qr/version check worker setup failed/,
        'mb642-821: echec de setup/watch_process garde une raison');
    $assert->like($reason // '', qr/version check worker pipe failed/,
        'mb652-821: echec pipe garde la raison historique');
    $assert->like($reason // '', qr/version check worker could not start/,
        'mb641-821: echec fork garde la raison historique');
    $assert->like($reason // '',
        qr/version check worker terminated by signal \$signal/,
        'mb641-821: signal garde sa raison');
    $assert->like($reason // '',
        qr/version check worker exited with status \$exit/,
        'mb641-821: exit non-zero garde sa raison');
    $assert->like($reason // '', qr/version check worker produced no result/,
        'mb641-821: payload vide garde sa raison');
    $assert->like($reason // '', qr/version check worker returned an invalid result/,
        'mb641-821: payload invalide garde sa raison');

    $assert->like($async // '',
        qr/_usable_local_version\(\$fallback_local\) \/\/ 'Undefined'/,
        'mb641-821: fallback local normalise sur les sorties terminales');

    $assert->like($async // '',
        qr/\$reason\s*=\s*\$why.*?defined\(\$why\).*?!ref\(\$why\).*?length\(\$why\)/s,
        'mb641-821: raison enfant valide preservee');

    $assert->like($async // '',
        qr/\$callback->\(\$local, \$remote, \$reason\)/,
        'mb652-821: callback historique trois arguments preserve');
};
