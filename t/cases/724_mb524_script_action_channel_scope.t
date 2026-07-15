# t/cases/724_mb524_script_action_channel_scope.t
# =============================================================================
# mb524 — garde de scope canal pour les actions de script (reply/notice).
#
# BUG : validate_action() n'utilisait le canal du contexte que comme DÉFAUT.
# Un script routé depuis une commande sur #test pouvait fournir
# target => "#autre" et faire écrire le bot dans un canal arbitraire
# (vecteur de spam / harcèlement cross-canal).
#
# CORRECTIF : si la cible résolue est un CANAL et qu'un canal de contexte
# existe, la cible doit être ce canal (comparaison insensible à la casse).
# Les cibles NICK (réponse en query) et l'absence de contexte restent permises.
#
# On teste directement validate_action (couche de décision de la cible).
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

use Mediabot::ScriptActionRunner;

sub _slurp_724 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }

{ package L724; sub new { bless {}, shift } sub log { } }

return sub {
    my ($assert) = @_;

    my $runner = Mediabot::ScriptActionRunner->new(logger => L724->new);
    my $ctx    = { channel => '#test' };

    my $check = sub {
        my ($action, $context) = @_;
        my ($ok, $err, $planned) = $runner->validate_action($action, $context);
        return ($ok ? 1 : 0, $err, $planned);
    };

    # --- cas légitimes : doivent PASSER ------------------------------------
    {
        my ($ok, $err, $p) = $check->({ type=>'reply', text=>'hi' }, $ctx);
        $assert->ok($ok && $p->{target} eq '#test', 'reply sans target -> canal du contexte');

        ($ok, $err, $p) = $check->({ type=>'reply', text=>'hi', target=>'#test' }, $ctx);
        $assert->ok($ok && $p->{target} eq '#test', 'reply canal explicite = contexte -> OK');

        ($ok, $err, $p) = $check->({ type=>'reply', text=>'hi', target=>'#TEST' }, $ctx);
        $assert->ok($ok, 'même canal, casse différente -> OK (insensible à la casse)');

        ($ok, $err, $p) = $check->({ type=>'notice', text=>'hi', target=>'TeuK' }, $ctx);
        $assert->ok($ok && $p->{target} eq 'TeuK', 'notice vers un NICK (query) -> OK');

        # STATUSMSG vers le meme canal reste dans le scope.
        ($ok, $err, $p) = $check->({ type=>'notice', text=>'hi', target=>'@#test' }, $ctx);
        $assert->ok($ok && $p->{target} eq '@#test', 'STATUSMSG @ vers le meme canal -> OK');

        ($ok, $err, $p) = $check->({ type=>'notice', text=>'hi', target=>'%#TEST' }, $ctx);
        $assert->ok($ok, 'STATUSMSG % vers le meme canal, casse differente -> OK');
    }

    # --- cas hostile : doit ÉCHOUER ----------------------------------------
    {
        my ($ok, $err, $p) = $check->({ type=>'reply', text=>'x', target=>'#autre' }, $ctx);
        $assert->ok(!$ok, 'reply vers un AUTRE canal -> rejeté');
        $assert->like($err // '', qr/out of scope/, 'message: out of scope');

        ($ok, $err, $p) = $check->({ type=>'notice', text=>'x', target=>'&secret' }, $ctx);
        $assert->ok(!$ok, 'notice vers un autre canal (&) -> rejeté aussi');

        # mb526: STATUSMSG ne doit pas contourner la garde en cachant le canal
        # derriere un prefixe de statut IRC.
        for my $status_target ('@#autre', '%#autre', '~#autre', '+#autre') {
            ($ok, $err, $p) = $check->({ type=>'reply', text=>'x', target=>$status_target }, $ctx);
            $assert->ok(!$ok, "STATUSMSG $status_target vers un autre canal -> rejete");
            $assert->like($err // '', qr/out of scope/, "STATUSMSG $status_target: message out of scope");
        }
    }

    # --- sans contexte de canal : comportement inchangé --------------------
    {
        my ($ok, $err, $p) = $check->({ type=>'reply', text=>'x', target=>'#anywhere' }, {});
        $assert->ok($ok && $p->{target} eq '#anywhere',
            'sans canal de contexte -> cible canal libre (inchangé)');
    }

    # --- garde de source ---------------------------------------------------
    {
        my $src = _slurp_724(File::Spec->catfile('.', 'Mediabot', 'ScriptActionRunner.pm'));
        $assert->like($src, qr/sub _channel_token_base/, 'helper _channel_token_base present');
        $assert->like($src, qr/target channel is out of scope/, 'garde de scope câblée');
        $assert->like($src, qr/lc\(\$target_channel_base\) ne lc\(\$ctx_channel_base\)/,
            'comparaison du canal canonique insensible a la casse');
        $assert->like($src, qr/\[~&@%\+\]\*\(\[#&!\+\]\.\*\)/,
            'prefixes STATUSMSG normalises avant le controle de scope');
    }
};
