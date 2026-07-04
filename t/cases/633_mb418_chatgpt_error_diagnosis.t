# t/cases/633_mb418_chatgpt_error_diagnosis.t
# =============================================================================
# mb418 — Les erreurs OpenAI sont diagnostiquées, plus masquées.
#
# Avant, toute erreur HTTP de chatGPT() se réduisait à « Sorry, API did not
# answer. » et le log ne montrait que status+reason : impossible de distinguer
# un rate-limit transitoire d'un quota épuisé (« ma clé est morte ? »). Un 429
# n'est pas une preuve de clé morte (une clé invalide donne typiquement 401). mb418 parse le corps JSON
# d'OpenAI (error.type / error.code / error.message), le journalise, et donne
# un message adapté :
#   insufficient_quota -> quota/crédits épuisés (facturation)
#   429 / rate_limit    -> rate limit, réessayer
#   401 / invalid_api_key -> clé rejetée
#   403                   -> accès/projet/région refusé, clé pas forcément invalide
# Le fallback modèle se déclenche aussi sur un 429 rate-limit (pas quota).
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;
use JSON::PP qw(decode_json);

sub _slurp_633 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }

return sub {
    my ($assert) = @_;

    my $src = _slurp_633(File::Spec->catfile('.', 'Mediabot', 'External', 'Claude.pm'));

    # --- 1. Le parseur et le classifieur, exécutés en isolation ------------
    my ($cause) = $src =~ /(sub _chatgpt_error_cause \{.*?\n\}\n)/s;
    my ($umsg)  = $src =~ /(sub _chatgpt_user_error_message \{.*?\n\}\n)/s;
    $assert->ok($cause && $umsg, 'parseur + classifieur présents');

    my ($fn_cause, $fn_msg);
    { no strict; no warnings;
      $fn_cause = eval "package T633; use JSON::PP qw(decode_json); $cause; \\&T633::_chatgpt_error_cause";
      $fn_msg   = eval "package T633; $umsg; \\&T633::_chatgpt_user_error_message"; }
    $assert->ok(ref($fn_cause) eq 'CODE' && ref($fn_msg) eq 'CODE', 'compilés en isolation');

    my $quota  = '{"error":{"message":"You exceeded your current quota","type":"insufficient_quota","code":"insufficient_quota"}}';
    my $rl     = '{"error":{"message":"Rate limit reached","type":"requests","code":"rate_limit_exceeded"}}';
    my $badkey = '{"error":{"message":"Incorrect API key provided","type":"invalid_request_error","code":"invalid_api_key"}}';

    my ($t,$c,$m) = $fn_cause->($quota);
    $assert->is($c, 'insufficient_quota', 'quota: code extrait');
    $assert->like($fn_msg->(429, $t, $c), qr/key accepted.*credits|budget/i, 'quota -> clé acceptée, action facturation');

    ($t,$c,$m) = $fn_cause->($rl);
    $assert->like($fn_msg->(429, $t, $c), qr/rate limit/i, 'rate-limit -> message réessayer');

    ($t,$c,$m) = $fn_cause->($badkey);
    $assert->like($fn_msg->(401, $t, $c), qr/rejected.*key|replace.*API_KEY/i, 'invalid_api_key -> remplacement de clé');

    $assert->like($fn_msg->(403, 'permission_error', 'access_denied'), qr/permission|not necessarily invalid/i, '403 -> permissions, pas faux diagnostic de clé morte');

    # corps vide/non-JSON -> pas de crash, message générique
    ($t,$c,$m) = $fn_cause->('');
    $assert->is("$t$c$m", '', 'corps vide -> cause vide');
    $assert->like($fn_msg->(500, '', ''), qr/service error|retry/i, 'erreur serveur -> réessayer');

    # --- 2. Câblage réel ----------------------------------------------------
    (my $code = $src) =~ s/^\s*#.*$//mg;
    $assert->like($code, qr/_chatgpt_error_cause\(\$http_response->\{content\}\)/,
        'la branche d\'erreur parse le corps de réponse');
    $assert->like($code, qr/\$primary_status == 429 && !\$quota_exhausted/,
        'fallback: 429 rate-limit éligible, pas insufficient_quota');
    $assert->like($code, qr/_chatgpt_user_error_message\(\$status, \$err_type, \$err_code\)/,
        'la branche HTTP délègue le message à _chatgpt_user_error_message');

    $assert->like($src, qr/mb418-B1/, 'tag mb418-B1');
};
