# t/cases/630_mb415_ai_summary_public_lines_help.t
# =============================================================================
# mb415 — "ai summary" : sortie publique optionnelle, longueur du résumé
# paramétrable, aide dédiée.
#
#   - public|pub : la réponse (feedback + résumé) part sur le CANAL courant
#     au lieu de notices ; l'historique de contexte claudeAI suit ($channel).
#   - <N>l : nombre de lignes du RÉSUMÉ (1..10, clampé). Le nombre NU reste,
#     comme avant, le nombre de MESSAGES analysés (rétro-compatible).
#   - help : usage complet en notices (syntaxe, périodes, options, exemples).
#   Les options sont acceptées à n'importe quelle position ; sans option, le
#   comportement historique est inchangé (notices, 2-3 phrases).
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

sub _slurp_630 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }

return sub {
    my ($assert) = @_;

    # --- 1. Sémantique du parsing d'options (reproduction fidèle) ----------
    my $parse = sub {
        my (@args) = @_;
        my ($p, $ol, $h) = (0, undef, 0);
        @args = grep {
            my $a = lc($_ // '');
            if    ($a eq 'public' || $a eq 'pub') { $p = 1; 0 }
            elsif ($a =~ /^(\d+)l$/)              { $ol = int($1); 0 }
            elsif ($a eq 'help')                  { $h = 1; 0 }
            else                                  { 1 }
        } @args;
        if (defined $ol) { $ol = 1 if $ol < 1; $ol = 10 if $ol > 10; }
        return ($p, $ol, $h, \@args);
    };

    my ($p, $ol, $h, $rest);
    ($p,$ol,$h,$rest) = $parse->('today','5l','public','teuk');
    $assert->ok($p==1 && $ol==5 && $h==0 && "@$rest" eq 'today teuk',
        'options extraites, filtre temporel + nick préservés');
    ($p,$ol,$h,$rest) = $parse->('10');
    $assert->ok($p==0 && !defined($ol) && "@$rest" eq '10',
        'nombre nu = nombre de messages (rétro-compatible)');
    ($p,$ol,$h,$rest) = $parse->('7d','3l');
    $assert->ok($ol==3 && "@$rest" eq '7d', 'Nd (jours) et Nl (lignes) coexistent');
    ($p,$ol,$h,$rest) = $parse->('50l');
    $assert->is($ol, 10, 'Nl clampé à 10');
    ($p,$ol,$h,$rest) = $parse->('pub');
    $assert->is($p, 1, 'alias pub accepté');
    ($p,$ol,$h,$rest) = $parse->('help');
    $assert->is($h, 1, 'help détecté');
    ($p,$ol,$h,$rest) = $parse->();
    $assert->ok($p==0 && !defined($ol) && $h==0, 'sans option: comportement historique');

    # --- 2. Scan source : câblage réel --------------------------------------
    my $src = _slurp_630(File::Spec->catfile('.', 'Mediabot', 'External', 'Claude.pm'));
    (my $code = $src) =~ s/^\s*#.*$//mg;

    $assert->like($code, qr/\$can_public = \$public_out && Mediabot::Helpers::isIrcChannelTarget\(\$channel\)/,
        'public: tout préfixe de canal IRC standard est accepté');
    $assert->like($code, qr/botPrivmsg\(\$self, \$channel, \$_\[0\]\)/,
        'sortie canal via botPrivmsg quand public');
    $assert->like($code, qr/claudeAI\(\$self, \$ctx->message, \$nick, \(\$can_public \? \$channel : undef\),\s*\n\s*\$send_out, \$summary_prompt\);/,
        'claudeAI: contexte aligné sur la destination');
    $assert->like($code, qr/in exactly \$out_lines short lines/,
        'prompt: nombre de lignes injecté');
    $assert->like($code, qr/'in 2-3 sentences'/,
        'défaut inchangé (2-3 phrases)');
    $assert->like($code, qr/Usage: ai summary \[last\|today\|yesterday\|week\|<N>d\] \[<N>\] \[<N>l\] \[public\] \[nick\]/,
        'aide inline: ligne usage');
    $assert->like($code, qr/Exemples: ai summary 5l public/,
        'aide inline: exemples');

    # L'aide interne (help ai) mentionne la nouvelle syntaxe.
    my $med = _slurp_630(File::Spec->catfile('.', 'Mediabot', 'Mediabot.pm'));
    $assert->like($med, qr/summary \[periode\] \[N\] \[Nl\] \[public\] \[nick\] \(details: ai summary help\)/,
        'help ai: syntaxe summary à jour');

    $assert->like($src, qr/mb415-R1/, 'tag mb415-R1');
    $assert->like($src, qr/mb416-B2/, 'tag mb416-B2');
};
