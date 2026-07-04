# t/cases/641_mb426_wordcount_accent_safe_split.t
# =============================================================================
# mb426 — wordcount ne fragmente plus les mots accentués français.
#
# La connexion DBI n'active pas le décodage UTF-8 (pas de mariadb_utf8, juste
# SET NAMES) : publictext arrive en OCTETS UTF-8. L'ancien split /\W+/ coupait
# sur chaque octet d'accent (café -> caf, réponse -> r + ponse), faussant le
# comptage et le "top words" sur un canal francophone. mb426 splitte en
# byte-safe : les octets >= 0x80 (séquences UTF-8 multi-octets) comptent comme
# des lettres, les mots accentués restent entiers.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;
use Encode ();

sub _slurp_641 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }

return sub {
    my ($assert) = @_;

    # --- 1. Sémantique du split byte-safe ----------------------------------
    my $bytes = Encode::encode('UTF-8', "café réponse à Noël, bonjour!");
    my %w;
    $w{lc $_}++ for split /[^0-9A-Za-z_\x80-\xFF]+/, $bytes;
    delete $w{''};
    my %seen = map { Encode::decode('UTF-8', $_) => 1 } keys %w;

    $assert->ok($seen{'café'},    'café reste entier');
    $assert->ok($seen{'réponse'}, 'réponse reste entier');
    $assert->ok($seen{'noël'},    'Noël reste entier (lc ASCII)');
    $assert->ok($seen{'bonjour'}, 'mot ASCII inchangé');
    $assert->ok(!$seen{'caf'},    'plus de fragment "caf"');
    $assert->ok(!$seen{'ponse'},  'plus de fragment "ponse"');

    # Comparaison directe avec l'ancien comportement (\W+ fragmentait).
    my @old = grep { length } split /\W+/, $bytes;
    my @new = grep { length } split /[^0-9A-Za-z_\x80-\xFF]+/, $bytes;
    $assert->ok(scalar(@new) < scalar(@old),
        'moins de fragments qu\'avec \W+ (mots accentués regroupés)');

    # --- 2. Câblage réel ---------------------------------------------------
    my $src = _slurp_641(File::Spec->catfile('.', 'Mediabot', 'UserCommands.pm'));
    my ($body) = $src =~ /(sub mbWordCount_ctx \{.*?\n\}\n)/s; $body //= '';
    (my $code = $body) =~ s/^\s*#.*$//mg;
    $assert->like($code, qr/split \/\[\^0-9A-Za-z_\\x80-\\xFF\]\+\//,
        'wordcount utilise le split byte-safe');
    $assert->unlike($code, qr/split \/\\W\+\//, 'plus de split \W+ dans wordcount');
    $assert->like($src, qr/mb426-B1/, 'tag mb426-B1');
};
