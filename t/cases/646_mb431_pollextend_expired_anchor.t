# t/cases/646_mb431_pollextend_expired_anchor.t
# =============================================================================
# mb431 — !pollextend repart de maintenant si la deadline est déjà passée.
#
# L'expiration des sondages est paresseuse : un sondage dont l'échéance est
# passée reste active=1 tant que personne n'a voté après. `!pollextend` faisait
# `deadline += $extra` sans condition -> pour un sondage déjà expiré,
# `deadline_passée + $extra` restait dans le passé : message "-Ns remaining"
# absurde et aucune vraie réouverture. mb431 ancre à max(now, deadline) avant
# d'ajouter $extra, garantissant une échéance future et un "remaining" positif.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

sub _slurp_646 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }

return sub {
    my ($assert) = @_;

    # --- 1. Sémantique -----------------------------------------------------
    my $ext = sub {
        my ($deadline, $now, $extra) = @_;
        my $base = $deadline // $now;
        $base = $now if $base < $now;
        my $new = $base + $extra;
        return ($new, $new - $now);   # (nouvelle deadline, remaining)
    };

    my ($new1, $rem1) = $ext->(1200, 1000, 60);   # future
    $assert->is($new1, 1260, 'deadline future: extension cumulée');
    $assert->is($rem1, 260,  'remaining = ancien + extra');

    my ($new2, $rem2) = $ext->(700, 1000, 60);    # déjà expirée
    $assert->is($new2, 1060, 'deadline passée: repart de maintenant');
    $assert->is($rem2, 60,   'remaining = extra (positif)');
    $assert->ok($rem2 > 0, 'remaining jamais négatif');

    # --- 2. Câblage réel ---------------------------------------------------
    my $src = _slurp_646(File::Spec->catfile('.', 'Mediabot', 'UserCommands.pm'));
    my ($body) = $src =~ /(sub mbPollExtend_ctx \{.*?\n\}\n)/s; $body //= '';
    (my $code = $body) =~ s/^\s*#.*$//mg;

    $assert->like($code, qr/my \$base = \$poll->\{deadline\} \/\/ time\(\);/,
        'base = deadline ou maintenant');
    $assert->like($code, qr/\$base = time\(\) if \$base < time\(\);/,
        'ancrage à maintenant si expiré');
    $assert->like($code, qr/\$poll->\{deadline\} = \$base \+ \$extra;/,
        'nouvelle deadline = base + extra');
    $assert->unlike($code, qr/\$poll->\{deadline\} = \(\$poll->\{deadline\} \/\/ time\(\)\) \+ \$extra;/,
        'plus d\'ajout inconditionnel');

    $assert->like($src, qr/mb431-B1/, 'tag mb431-B1');
};
