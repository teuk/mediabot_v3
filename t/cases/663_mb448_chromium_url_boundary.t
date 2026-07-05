# t/cases/663_mb448_chromium_url_boundary.t
# =============================================================================
# mb448 — Revue sécurité pré-release (P0.7/C4) : garde de frontière Chromium.
#
# _fetch_url_chromium_dumpdom est la dernière frontière avant open3() ; $url
# est le dernier élément de l'argv Chromium. Une chaîne commençant par '-'
# serait interprétée comme une OPTION Chromium (même classe que l'injection
# yt-dlp mb417). Les appelants actuels valident ^https?:// en amont, mais la
# frontière ne doit pas dépendre de leur discipline : la fonction refuse
# désormais tout argument qui n'est pas une URL http(s) absolue.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

sub _slurp_663 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }

return sub {
    my ($assert) = @_;

    # --- 1. Sémantique de la garde -----------------------------------------
    my $accepted = sub { my ($u) = @_; ($u =~ m{\Ahttps?://}i) ? 1 : 0 };

    $assert->is($accepted->('https://instagram.com/p/x'), 1, 'https accepté');
    $assert->is($accepted->('http://example.com'),         1, 'http accepté');
    $assert->is($accepted->('HTTPS://X.COM/a'),            1, 'casse indifférente');
    $assert->is($accepted->('--enable-logging=stderr'),    0, 'option Chromium refusée');
    $assert->is($accepted->('--headless=old'),             0, 'option Chromium refusée (2)');
    $assert->is($accepted->('file:///etc/passwd'),         0, 'file:// refusé');
    $assert->is($accepted->('javascript:alert(1)'),        0, 'javascript: refusé');
    $assert->is($accepted->('ftp://host/x'),               0, 'schéma non http(s) refusé');

    # --- 2. Câblage réel ----------------------------------------------------
    my $src = _slurp_663(File::Spec->catfile('.', 'Mediabot', 'External', 'URL.pm'));
    my ($body) = $src =~ /(sub _fetch_url_chromium_dumpdom \{.*?\n\}\n)/s; $body //= '';
    (my $code = $body) =~ s/^\s*#.*$//mg;

    $assert->like($code, qr/unless \(\$url =~ m\{\\Ahttps\?:\/\/\}i\)/,
        'garde ^https?:// présente dans la fonction');
    # La garde est placée AVANT la construction de l'argv/open3.
    my $guard_pos = index($code, 'Ahttps?://');
    my $open3_pos = index($code, 'open3(');
    $assert->ok($guard_pos >= 0 && $open3_pos > $guard_pos,
        'garde évaluée avant open3()');
    $assert->like($src, qr/mb448-B1/, 'tag mb448-B1');
};
