# t/cases/703_mb493_chromium_sigtrap_fix.t
# =============================================================================
# mb493 — chromium mourait en prod par SIGTRAP (signal 5) au démarrage :
# Facebook/X (et Instagram, sans fallback) ne rendaient jamais de DOM.
#
# Causes traitées dans _fetch_url_chromium_dumpdom :
#   [1] profil par défaut inutilisable en service systemd (HOME confiné) et
#       SingletonLock partagé entre invocations -> --user-data-dir JETABLE et
#       UNIQUE sous /tmp/mediabot-chromium, avec purge opportuniste (>10 min) ;
#   [2] crashpad qui trap en environnement confiné -> --disable-crash-reporter
#       + --disable-breakpad + --no-first-run + --no-default-browser-check ;
#   [3] --headless=new fragile sur Chrome récent -> --headless (mode moderne
#       par défaut) ;
#   [4] DEBUG demandé : le stderr de chromium n'était JAMAIS loggé sur le
#       chemin signal -> loggé (DEBUG3, 700 car, aplati) pour diagnostiquer.
#
# Garde par scan de source (pattern projet pour les invocations externes).
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

sub _slurp_703 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }

return sub {
    my ($assert) = @_;

    my $src = _slurp_703(File::Spec->catfile('.', 'Mediabot', 'External', 'URL.pm'));
    my ($fn) = $src =~ /(sub _fetch_url_chromium_dumpdom \{.*?\n\})\n\nsub /s;
    $fn //= '';
    $assert->ok($fn ne '', '_fetch_url_chromium_dumpdom localisé');

    # --- [1] profil jetable unique + purge -----------------------------------
    $assert->like($fn, qr{my \$profile_base = '/tmp/mediabot-chromium';},
        '[1] base de profils jetables sous /tmp');
    $assert->like($fn, qr/sprintf\('%s\/p%d\.%d\.%d', \$profile_base, \$\$, time\(\), int\(rand\(/,
        '[1] répertoire de profil UNIQUE (pid + time + rand)');
    $assert->like($fn, qr/"--user-data-dir=\$profile_dir"/,
        '[1] --user-data-dir pointe le profil jetable');
    $assert->like($fn, qr/\$now - \$m > 600/,
        '[1] purge opportuniste des profils > 10 min');
    $assert->like($fn, qr/File::Path::remove_tree\(\$p\)/,
        '[1] purge via remove_tree (encapsulée dans eval)');

    # --- [2] flags anti-crashpad ---------------------------------------------
    for my $flag ('--no-first-run', '--no-default-browser-check',
                  '--disable-crash-reporter', '--disable-breakpad') {
        $assert->like($fn, qr/'\Q$flag\E'/, "[2] flag $flag présent");
    }

    # --- [3] --headless moderne ----------------------------------------------
    $assert->like($fn, qr/'--headless',/, '[3] --headless (mode moderne)');
    $assert->unlike($fn, qr/--headless=new/, '[3] plus de --headless=new fragile');

    # --- [4] stderr loggé sur le chemin signal --------------------------------
    my ($sigblock) = $fn =~ /(if \(\$signal\) \{.*?return undef;\s*\})/s;
    $sigblock //= '';
    $assert->ok($sigblock ne '', '[4] bloc signal localisé');
    $assert->like($sigblock, qr/terminated by signal \$signal/,
        '[4] le signal est loggé');
    $assert->like($sigblock, qr/\$stderr_txt/,
        '[4] le stderr chromium est loggé sur signal (diagnosable)');
    $assert->like($sigblock, qr/substr\(\$stderr_txt, 0, 700\)/,
        '[4] stderr tronqué à 700 caractères');

    # --- non-régression : la frontière sécurité mb448 est intacte -------------
    $assert->like($fn, qr/refused non-http\(s\) argument/,
        'frontière mb448 (URL http(s) only) intacte');
    # l'URL reste le DERNIER argument, après --dump-dom
    $assert->like($fn, qr/'--dump-dom',\s*\n\s*\$url,\s*\n\s*\);/,
        'l\'URL reste le dernier argument après --dump-dom');
};
