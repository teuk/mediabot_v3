# t/cases/672_mb459_karma_current_score_helper.t
# =============================================================================
# mb459/mb464 — helper unique de score karma courant.
#
# Le helper accepte désormais un canal optionnel et départage explicitement les
# timestamps égaux. Les deux commandes continuent de déléguer à une seule source
# de vérité.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

sub _slurp_672 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }

return sub {
    my ($assert) = @_;
    my $src = _slurp_672(File::Spec->catfile('.', 'Mediabot', 'UserCommands.pm'));

    my $defs = () = $src =~ /^sub _karma_current_score \{/mg;
    $assert->is($defs, 1, '_karma_current_score défini exactement une fois');

    my ($helper) = $src =~ /(sub _karma_current_score \{.*?^\}\n)/ms;
    $helper //= '';
    $assert->like($helper, qr/my \(\$self, \$nick, \$channel\) = \@_;/,
        'helper accepte un canal optionnel');
    $assert->like($helper, qr/grep \{ lc\(\$_\) eq lc\(\$channel\) \}/,
        'helper filtre les entrées sur le canal demandé');
    $assert->like($helper, qr/\$ts == \$best_ts.*?\$channel_key gt \$best_channel/s,
        'helper possède un départage déterministe en cas de timestamp égal');
    $assert->like($helper, qr/\$idx > \$best_index/,
        'dans un même canal, l’entrée la plus tardive gagne à timestamp égal');
    $assert->like($helper, qr/return defined \$best \? \$best->\{score\} : undef;/,
        'helper retourne score ou undef');

    $assert->like($src, qr/_karma_current_score\(\$self, \$wt\)/,
        '!karmawatch list conserve la vue globale');
    $assert->like($src, qr/_karma_current_score\(\$self, \$target, \$kd_chan\)/,
        '!karmadiff transmet son canal');
    my $calls = () = $src =~ /= _karma_current_score\(\$self,/g;
    $assert->is($calls, 2, 'exactement deux appelants réels du helper');

    my $bad = () = $src =~ /grep \{ lc\(\$_->\{nick\}\) eq lc\(\$\w+\) \} reverse \@\$k?log\b[^;]*;\s*\n\s*if \([^)]*\{score\}[^)]*\) \{\s*\n[^\n]*; last;/g;
    $assert->is($bad, 0, 'ancien anti-pattern absent');
};
