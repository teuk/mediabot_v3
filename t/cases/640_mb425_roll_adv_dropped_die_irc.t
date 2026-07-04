# t/cases/640_mb425_roll_adv_dropped_die_irc.t
# =============================================================================
# mb425 — !roll adv/dis : le dé écarté utilise le barré IRC, pas Markdown.
#
# L'affichage advantage/disadvantage montrait le dé abandonné en "~~8~~"
# (strikethrough Markdown/Discord), qui apparaît en tildes littéraux sur IRC.
# mb425 utilise le vrai code de barré IRC \x1e (rendu par mIRC/HexChat/WeeChat/
# Kiwi) suivi d'un reset \x0f, en gardant le nombre lisible partout.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

sub _slurp_640 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }

return sub {
    my ($assert) = @_;

    my $src = _slurp_640(File::Spec->catfile('.', 'Mediabot', 'UserCommands.pm'));
    my ($body) = $src =~ /(sub mbRoll_ctx \{.*?\n\}\n)/s; $body //= '';
    $assert->ok($body ne '', 'mbRoll_ctx extraite');
    (my $code = $body) =~ s/^\s*#.*$//mg;

    # Plus de strikethrough Markdown.
    $assert->unlike($code, qr/~~%d~~/, 'plus de barré Markdown ~~..~~');
    $assert->unlike($code, qr/~~/,     'aucun ~~ résiduel');

    # Le dé écarté est barré via \x1e ... \x0f.
    $assert->like($code, qr/\$drop_str = "\\x1e\$drop\\x0f";/,
        'dé écarté barré via \x1e/\x0f (codes IRC)');
    $assert->like($code, qr/\[%d, %s\]/, 'format: kept + drop_str');

    # --- Simulation du rendu ----------------------------------------------
    my ($kept,$drop,$adv_mode,$label,$nick,$modifier)=(15,8,'adv','1d20','teuk',0);
    my $total=$kept+$modifier; my $mod_str=$modifier?sprintf(' %+d = %d',$modifier,$total):'';
    my $drop_str="\x1e$drop\x0f";
    my $out=sprintf('%s rolled %s (%s): [%d, %s]%s',$nick,$label,$adv_mode,$kept,$drop_str,$mod_str);
    $assert->ok(index($out, "\x1e8\x0f") >= 0, 'le dé écarté est bien barré (8 entre \x1e et \x0f)');
    $assert->ok(index($out, '~~') < 0,          'aucun tilde dans la sortie');

    $assert->like($src, qr/mb425-R1/, 'tag mb425-R1');
};
