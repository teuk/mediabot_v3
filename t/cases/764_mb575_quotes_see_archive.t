# t/cases/764_mb575_quotes_see_archive.t
# =============================================================================
# mb575 (refondu par mb576) — les lecteurs de TEXTE voient vif + archive via
# des requetes PAR TABLE (channel_log_gather), avec fusion triee cote Perl :
#   [1] wordcount / last / compat utilisent le gather ;
#   [2] last est le cas d'ecole : LIMIT par table puis tri desc + splice
#       (jamais d'ORDER/LIMIT sur une derivee UNION) ;
#   [3] mood reste STRICTEMENT sur le vif (fenetres recentes) ;
#   [4] la tokenisation byte-safe mb426/mb427 est conservee.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

sub _slurp_764 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }

sub _sub_src_764 {
    my ($src, $name) = @_;
    my ($body) = $src =~ /(sub \Q$name\E \{.*?\n\})/s;
    return $body;
}

return sub {
    my ($assert) = @_;

    my $src = _slurp_764(File::Spec->catfile('Mediabot', 'UserCommands.pm'));

    # [1] les trois lecteurs de texte
    for my $sub_name (qw(mbWordCount_ctx mbLast_ctx mbCompat_ctx)) {
        my $body = _sub_src_764($src, $sub_name);
        $assert->ok(defined $body, "$sub_name isolee");
        $assert->like($body, qr/Mediabot::Helpers::channel_log_gather/,
            "$sub_name: requetes par table via channel_log_gather");
        $assert->like($body, qr/__CLSRC__/,
            "$sub_name: template avec token __CLSRC__");
    }

    # [2] last : fusion triee ts desc puis splice au plafond demande
    my $last = _sub_src_764($src, 'mbLast_ctx');
    $assert->like($last,
        qr/sort \{ \(\$b->\{ts\} \/\/ ''\) cmp \(\$a->\{ts\} \/\/ ''\) \}/,
        'last: tri desc de la fusion');
    $assert->like($last, qr/splice\(\@rows, \$limit\)/,
        'last: plafond applique apres fusion');

    # wordcount garde son ORDER BY id (coherence PK, preservees au deplacement)
    my $wc = _sub_src_764($src, 'mbWordCount_ctx');
    $assert->like($wc, qr/ORDER BY cl\.id_channel_log DESC/,
        'wordcount: ordre PK conserve par table');

    # [3] mood: aucun gather
    my $mood = _sub_src_764($src, 'mbMood_ctx');
    $assert->ok(defined $mood && $mood !~ /channel_log_gather/,
        'mood: fenetres recentes, vif seulement');

    # [4] tokenisation byte-safe conservee (wordcount et compat)
    my $compat = _sub_src_764($src, 'mbCompat_ctx');
    for my $pair ([wordcount => $wc], [compat => $compat]) {
        my ($n, $b) = @$pair;
        $assert->like($b, qr/\[\^0-9A-Za-z_\\x80-\\xFF\]\+/,
            "$n: split byte-safe mb426/mb427 conserve");
    }
};
