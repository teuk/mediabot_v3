# t/cases/642_mb427_compat_mood_accent_safe.t
# =============================================================================
# mb427 — compat et mood tokenisent en byte-safe (harmonisation avec mb426).
#
# Même cause que mb426 : publictext arrive en OCTETS UTF-8 (DBI ne décode pas).
# mbCompat_ctx (vocabulaire jaccard) et mbMood_ctx (sentiment) faisaient
# `s/[^\w\s\x{00C0}-\x{017F}]/ /g` puis split /\s+/ ; sur des octets, ce motif
# gardait même un octet parasite (café -> "caf\xC3") et fragmentait les mots.
# Conséquences : jaccard vocab faux, et surtout les mots de sentiment accentués
# du dictionnaire FR (raté, pitié, énervé, géniale...) n'étaient JAMAIS
# reconnus. mb427 utilise le split byte-safe de mb426.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;
use Encode ();

sub _slurp_642 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }

return sub {
    my ($assert) = @_;

    # --- 1. Sémantique : un mot de sentiment accentué est reconnu ----------
    my %neg_h = map { Encode::encode('UTF-8', $_) => 1 } ('raté', 'pitié', 'énervé');
    my $txt   = Encode::encode('UTF-8', "cette release est complètement ratée, quelle pitié");
    my $lower = lc($txt);

    my @old = grep { length >= 2 } do {
        (my $t = $lower) =~ s/[^\w\s\x{00C0}-\x{017F}]/ /g; split /\s+/, $t;
    };
    my @new = grep { length >= 2 } split /[^0-9A-Za-z_\x80-\xFF]+/, $lower;

    my $old_hits = grep { $neg_h{$_} } @old;
    my $new_hits = grep { $neg_h{$_} } @new;
    $assert->ok($new_hits >= 1, 'byte-safe: mot de sentiment accentué reconnu (pitié)');
    $assert->ok($new_hits > $old_hits, 'byte-safe reconnaît plus que l\'ancien motif');

    # café reste entier
    my %seen = map { Encode::decode('UTF-8', $_) => 1 }
               split /[^0-9A-Za-z_\x80-\xFF]+/, Encode::encode('UTF-8','un café serré');
    $assert->ok($seen{'café'}, 'café entier');
    $assert->ok(!$seen{'caf'}, 'plus de fragment caf');

    # --- 2. Câblage réel ---------------------------------------------------
    my $src = _slurp_642(File::Spec->catfile('.', 'Mediabot', 'UserCommands.pm'));
    (my $code = $src) =~ s/^\s*#.*$//mg;

    for my $sub (qw(mbCompat_ctx mbMood_ctx)) {
        my ($body) = $code =~ /(sub \Q$sub\E \{.*?\n\}\n)/s; $body //= '';
        $assert->like($body, qr/split \/\[\^0-9A-Za-z_\\x80-\\xFF\]\+\//,
            "$sub: split byte-safe");
        $assert->unlike($body, qr/\[\^\\w\\s\\x\{00C0\}/,
            "$sub: plus de motif x{00C0}-x{017F} non sûr");
    }
    $assert->like($src, qr/mb427-B1/, 'tag mb427-B1');
};
