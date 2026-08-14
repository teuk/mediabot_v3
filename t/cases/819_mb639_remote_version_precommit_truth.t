# t/cases/819_mb639_remote_version_precommit_truth.t
# =============================================================================
# mb639 — garde pre-commit du diagnostic de version distante.
#   [1] VERSION_URL est un vrai override (une seule source) ;
#   [2] VERSION_TIMEOUT est par URL et le worker couvre toutes les tentatives ;
#   [3] update_ctx ne reimpose plus un timeout fixe plus court ;
#   [4] un HTTP 200 doit contenir une vraie version Mediabot ;
#   [5] une ancienne raison d'echec ne fuit pas vers le check suivant.
# =============================================================================

use strict;
use warnings;
use utf8;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }

sub _slurp_819 {
    my ($p) = @_;
    open my $fh, '<:encoding(UTF-8)', $p or die "$p: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    my $hsrc = _slurp_819('Mediabot/Helpers.pm');
    my $usrc = _slurp_819('Mediabot/Update.pm');
    my $conf = _slurp_819('mediabot.sample.conf');

    # [1] vrai override : une URL configuree remplace la liste.
    $assert->like($hsrc,
        qr/sub _remote_version_urls \{.*?return \(\$conf_url\);.*?return \@VERSION_URLS;/s,
        'mb639-819: VERSION_URL remplace la liste par defaut');
    $assert->like($conf, qr/VERSION_URL is a TRUE override/,
        'mb639-819: le sample conf dit le meme contrat');

    # [2] budget = timeout par URL * nombre d URL + marge.
    $assert->like($hsrc,
        qr/sub _remote_version_worker_timeout \{.*?\$per_url \* \(\@urls \|\| 1\).*?\+ 1/s,
        'mb639-819: le budget worker couvre chaque source');
    $assert->like($hsrc,
        qr/\$timeout = _remote_version_worker_timeout\(\$self\)/,
        'mb639-819: getVersion_async utilise ce budget par defaut');
    $assert->like($hsrc, qr/\$timeout = 65\s+if \$timeout > 65/,
        'mb639-819: le budget async reste borne');
    $assert->like($conf, qr/VERSION_TIMEOUT is the timeout PER URL/,
        'mb639-819: la portee du timeout est documentee');

    # [3] la commande update ne raccourcit plus le worker a 8 secondes.
    $assert->unlike($usrc,
        qr/getVersion_async\(\$self,\s*\$done,\s*timeout\s*=>\s*8\)/,
        'mb639-819: update_ctx ne tue plus le worker avant le miroir');
    $assert->like($usrc,
        qr/getVersion_async\(\$self,\s*\$done\)/,
        'mb639-819: update_ctx delegue le budget au helper');

    # [4] 200 + texte quelconque n'est pas une version.
    $assert->like($hsrc,
        qr/length\(\$body\) > 256 \|\| \$body =~ \/\[\\r\\n\]\/ \|\| !_version_parts\(\$body\)/,
        'mb639-819: le corps HTTP doit parser comme une version Mediabot');

    # [5] aucune raison stale entre deux checks.
    $assert->like($hsrc,
        qr/\$self->\{_version_fetch_error\} = undef if ref\(\$self\);/,
        'mb639-819: getVersion efface la raison precedente avant le check');

    # Le diagnostic affiche les sources reellement selectionnees, pas toujours
    # la premiere URL hardcodee.
    $assert->like($usrc,
        qr/Mediabot::Helpers::_remote_version_urls\(\$self\)/,
        'mb639-819: le message d erreur utilise les sources effectives');
    $assert->unlike($usrc,
        qr/\.\s*\$Mediabot::Helpers::VERSION_URLS\[0\]\s*\./,
        'mb639-819: le diagnostic n annonce plus systematiquement raw GitHub');
};
