# t/cases/674_mb461_youtube_id_v_param_boundary.t
# =============================================================================
# mb461/mb464 — Radio::Request::_extract_youtube_id : URL YouTube réelle.
#
# Une frontière \bv= ne suffit pas : example.org/?v=..., /shorts/ sur un autre
# host, ou notyoutu.be/ restent des faux positifs. Le parseur reconnaît désormais
# explicitement les hosts et chemins YouTube supportés.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

sub _slurp_674 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }

sub _ex674 {
    my ($text) = @_;
    return undef unless defined($text) && $text ne '';
    if ($text =~ m{https?://(?:www\.|m\.|music\.)?youtube\.com/watch\?([^\s#]*)}i) {
        my $query = $1;
        return $1 if $query =~ /(?:^|&)v=([A-Za-z0-9_-]{11})(?:&|$)/;
    }
    return $1 if $text =~ m{https?://(?:www\.)?youtu\.be/([A-Za-z0-9_-]{11})(?=[/?#&\s]|$)}i;
    return $1 if $text =~ m{https?://(?:www\.|m\.)?youtube\.com/shorts/([A-Za-z0-9_-]{11})(?=[/?#&\s]|$)}i;
    return $1 if $text =~ /^([A-Za-z0-9_-]{11})$/;
    return undef;
}

return sub {
    my ($assert) = @_;

    $assert->is(_ex674('https://youtube.com/watch?v=dQw4w9WgXcQ'), 'dQw4w9WgXcQ',
        'watch?v= extrait l’ID');
    $assert->is(_ex674('https://music.youtube.com/watch?list=X&v=dQw4w9WgXcQ&feature=share'), 'dQw4w9WgXcQ',
        'v complet au milieu de la query extrait l’ID');
    $assert->is(_ex674('https://youtu.be/dQw4w9WgXcQ?t=4'), 'dQw4w9WgXcQ',
        'youtu.be extrait l’ID');
    $assert->is(_ex674('https://m.youtube.com/shorts/dQw4w9WgXcQ?feature=share'), 'dQw4w9WgXcQ',
        'shorts sur host YouTube extrait l’ID');
    $assert->is(_ex674('dQw4w9WgXcQ'), 'dQw4w9WgXcQ', 'ID nu extrait');

    for my $bad (
        'https://example.org/?v=dQw4w9WgXcQ',
        'https://notyoutube.com/watch?v=dQw4w9WgXcQ',
        'https://notyoutu.be/dQw4w9WgXcQ',
        'https://example.org/shorts/dQw4w9WgXcQ',
        'https://foo.com/x?adv=dQw4w9WgXcQ',
    ) {
        $assert->ok(!defined _ex674($bad), "faux host/path refusé: $bad");
    }

    my $src = _slurp_674(File::Spec->catfile('.', 'Mediabot', 'Radio', 'Request.pm'));
    my ($sub) = $src =~ /(sub _extract_youtube_id \{.*?^\}\n)/ms;
    $sub //= '';
    $assert->like($sub, qr/youtube\\\.com\/watch/, 'host youtube.com vérifié explicitement');
    $assert->like($sub, qr/\(\?:\^\|&\)v=/, 'v doit être un paramètre complet');
    $assert->like($sub, qr/youtu\\\.be\//, 'host youtu.be vérifié explicitement');
    $assert->unlike($sub, qr/\(\?:\\bv=\|youtu/, 'ancien motif sous-chaîne supprimé');
    $assert->like($sub, qr/mb461\/mb464/, 'tag mb464 présent');
};
