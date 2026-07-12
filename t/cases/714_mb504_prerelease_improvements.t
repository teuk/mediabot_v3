# t/cases/714_mb504_prerelease_improvements.t
# =============================================================================
# mb504 — améliorations pré-release 3.3 (roadmap section 2.2), sans schéma.
#
#   [1] !milestone : affiche aussi le DERNIER palier franchi (sentiment
#       d'accomplissement) + "just hit N!" quand le total tombe pile ;
#       helper _milestone_last (symétrique de _milestone_next).
#   [2] !recap ai : le résumé IA est BORNÉ en nombre de lignes émises
#       (anti-flood, leçon MB488) — au-delà, une ligne de troncature.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

use Mediabot::UserCommands;

sub _slurp_714 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }

return sub {
    my ($assert) = @_;

    # --- [1] _milestone_last : symétrie et bornes --------------------------
    {
        $assert->is(Mediabot::UserCommands::_milestone_last(500),     0,       '[1] 500 -> 0 (avant 1er palier)');
        $assert->is(Mediabot::UserCommands::_milestone_last(1000),    1000,    '[1] 1000 -> 1000 (pile)');
        $assert->is(Mediabot::UserCommands::_milestone_last(5000),    5000,    '[1] 5000 -> 5000');
        $assert->is(Mediabot::UserCommands::_milestone_last(98750),   95000,   '[1] 98750 -> 95000');
        $assert->is(Mediabot::UserCommands::_milestone_last(100000),  100000,  '[1] 100000 -> 100000');
        $assert->is(Mediabot::UserCommands::_milestone_last(543210),  500000,  '[1] 543210 -> 500000');
        $assert->is(Mediabot::UserCommands::_milestone_last(1234567), 1200000, '[1] 1.23M -> 1.2M');

        # cohérence last <= n < next
        for my $n (1234, 9999, 47000, 250000, 2500000) {
            my $last = Mediabot::UserCommands::_milestone_last($n);
            my $next = Mediabot::UserCommands::_milestone_next($n);
            $assert->ok($last <= $n && $n < $next, "[1] last<=n<next pour n=$n");
        }

        # câblage dans mbMilestone_ctx
        my $uc = _slurp_714(File::Spec->catfile('.', 'Mediabot', 'UserCommands.pm'));
        my ($fn) = $uc =~ /(sub mbMilestone_ctx \{.*?\n\})/s; $fn //= '';
        $assert->like($fn, qr/_milestone_last\(\$total\)/, '[1] mbMilestone appelle _milestone_last');
        $assert->like($fn, qr/last passed/, '[1] libellé "last passed"');
        $assert->like($fn, qr/just hit/, '[1] libellé "just hit" (pile sur un palier)');
    }

    # --- [2] recap AI : cap du nombre de lignes ----------------------------
    {
        my $uc = _slurp_714(File::Spec->catfile('.', 'Mediabot', 'UserCommands.pm'));
        my ($fn) = $uc =~ /(sub mbRecap_ctx \{.*?\n\})/s; $fn //= '';
        $assert->like($fn, qr/\$ai_max_lines\s*=\s*\d+/, '[2] cap de lignes défini');
        $assert->like($fn, qr/\$sent_lines >= \$ai_max_lines/, '[2] garde sur le compteur de lignes');
        $assert->like($fn, qr/summary truncated/, '[2] message de troncature');

        # simulation de la logique de cap (réplique fidèle du callback)
        my $cap = sub {
            my ($text, $max) = @_;
            my @out; my $sent = 0; my $truncated = 0;
            for my $line (split /\n/, $text) {
                next if $line =~ /^\s*$/;
                if ($sent >= $max) { $truncated = 1; last; }
                push @out, $line; $sent++;
            }
            return (\@out, $truncated);
        };
        my $long = join("\n", map { "line $_" } 1..40);
        my ($out, $trunc) = $cap->($long, 12);
        $assert->is(scalar(@$out), 12, '[2] au plus 12 lignes émises');
        $assert->ok($trunc, '[2] troncature signalée sur texte long');

        my $short = "une seule ligne de résumé";
        my ($out2, $trunc2) = $cap->($short, 12);
        $assert->is(scalar(@$out2), 1, '[2] texte court non tronqué');
        $assert->ok(!$trunc2, '[2] pas de troncature si court');
    }
};
