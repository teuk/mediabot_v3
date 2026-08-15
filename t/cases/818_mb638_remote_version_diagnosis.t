# t/cases/818_mb638_remote_version_diagnosis.t
# =============================================================================
# mb638 — « m update » doit DIRE pourquoi la version distante manque.
#
# TERRAIN (#teuk) : « local: 3.4dev-... | github: Undefined » puis « Cannot
# check: version could not be determined » — aucune prise pour l'operateur.
# La cause etait structurelle et venait de MON mb631 : j'ai bati la commande
# sur getVersion_async, dont le FILS tourne avec un logger volontairement muet
# (_SilentLogger). getVersion journalisait bien « Failed to fetch ... HTTP
# 599 », mais dans le fils cette ligne partait au neant : panne reseau et
# absence de version devenaient indiscernables.
#
#   [1] fetch_remote_version rend (version, RAISON) — une seule
#       implementation, celle que getVersion consomme aussi.
#   [2] chaque mode de panne a sa raison propre : HTTPS indisponible, HTTP
#       non-200, corps vide, contenu qui n'est pas un fichier VERSION.
#   [3] deux URL essayees ; la premiere qui repond gagne, et la conf peut en
#       imposer une.
#   [4] la raison TRAVERSE le tuyau enfant -> parent (3e valeur du payload)
#       et arrive au callback.
#   [5] la commande AFFICHE la raison et le point de lecture, au lieu du
#       « could not be determined » aveugle.
#   [6] rien ne casse quand tout va bien : la version est rendue nue.
# =============================================================================

use strict;
use warnings;
use utf8;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }

{ package ConfV; sub new { bless { kv => $_[1] || {} }, $_[0] } sub get { $_[0]{kv}{$_[1]} } }
{ package LogV;  sub new { bless { l => [] }, shift } sub log { push @{$_[0]{l}}, $_[2]; 1 } }
{
    package CtxV;
    sub new { my ($c,%a)=@_; bless { %a }, $c }
    sub bot { $_[0]{bot} } sub nick { 'teuk' } sub channel { '#teuk' }
    sub args { $_[0]{args} || [] } sub message { {} } sub require_level { 1 }
}

return sub {
    my ($assert) = @_;

    require Mediabot::Helpers;
    require Mediabot::Update;
    require HTTP::Tiny;

    my $bot = bless { conf => ConfV->new, logger => LogV->new }, 'Mediabot';
    my $F = Mediabot::Helpers->can('fetch_remote_version');
    $assert->ok($F, 'mb638-818: le fetch est expose et factorise');
    my $URLS = Mediabot::Helpers->can('_remote_version_urls');
    my $WT   = Mediabot::Helpers->can('_remote_version_worker_timeout');
    $assert->ok($URLS && $WT,
        'mb639-818: plan URL et budget worker sont des helpers uniques');

    # [2] chaque panne a SA raison
    my @asked;
    no warnings 'redefine';
    my $reply = { success => 0, status => 599, content => 'SSL connect attempt failed' };
    local *HTTP::Tiny::get = sub { push @asked, $_[1]; return $reply };
    local *HTTP::Tiny::can_ssl = sub { 1 };

    my ($v, $why) = $F->($bot);
    $assert->ok(!defined $v, 'mb638-818: echec reseau -> aucune version');
    $assert->like($why, qr/HTTP 599/, 'mb638-818: ... le statut est dit');
    $assert->like($why, qr/SSL connect attempt failed/,
        'mb638-818: ... et le detail reseau aussi (599 met la cause dans le corps)');
    $assert->is(scalar @asked, 2, 'mb638-818: les DEUX URL ont ete essayees');

    { local *HTTP::Tiny::can_ssl = sub { 0 };
      my (undef, $w) = $F->($bot);
      $assert->like($w, qr/HTTPS unavailable.*IO::Socket::SSL/,
        'mb638-818: sans support HTTPS, on le dit au lieu d un 599 opaque'); }

    $reply = { success => 1, status => 200, content => "   \n" };
    (my $v2, $why) = $F->($bot);
    $assert->ok(!defined $v2 && $why =~ /empty VERSION file/,
        'mb638-818: un fichier vide est une panne, pas une version');

    $reply = { success => 1, status => 200,
               content => "<html><head><title>Proxy</title></head>\n<body>blocked</body></html>" };
    (my $v3, $why) = $F->($bot);
    $assert->ok(!defined $v3 && $why =~ /unexpected content/,
        'mb638-818: une page de proxy n est JAMAIS prise pour une version');

    $reply = { success => 1, status => 200, content => '<html>blocked</html>' };
    (my $v3b, $why) = $F->($bot);
    $assert->ok(!defined $v3b && $why =~ /unexpected content/,
        'mb639-818: meme une page HTML courte sur une ligne est refusee');

    # [6] cas nominal
    $reply = { success => 1, status => 200, content => "3.4dev-20260814_054627\n" };
    (my $ok_v, my $ok_w) = $F->($bot);
    $assert->is($ok_v, '3.4dev-20260814_054627', 'mb638-818: version rendue nue');
    $assert->ok(!defined $ok_w, 'mb638-818: ... et aucune raison quand tout va bien');
    $reply = { success => 1, status => 200, content => "\x{FEFF}3.4dev-1\n" };
    $assert->is(($F->($bot))[0], '3.4dev-1', 'mb638-818: un BOM ne casse rien');

    # [3] la conf impose UNE URL : c'est un override, pas une URL ajoutee
    @asked = ();
    $reply = { success => 1, status => 200, content => "3.4dev-2\n" };
    my $tuned = bless { conf => ConfV->new({ 'update.VERSION_URL' => 'https://miroir.example/V' }),
                        logger => LogV->new }, 'Mediabot';
    $F->($tuned);
    $assert->is($asked[0], 'https://miroir.example/V',
        'mb638-818: la conf impose son URL');
    $assert->is(scalar @asked, 1,
        'mb639-818: VERSION_URL force UNE seule source, sans fallback GitHub');
    # mb640: _remote_version_urls rend une LISTE. « scalar(liste) » rend son
    # DERNIER element, pas son compte — d'ou un test rouge pour un code juste.
    my @tuned_urls = $URLS->($tuned);
    $assert->is(scalar(@tuned_urls), 1,
        'mb639-818: le plan interne contient lui aussi une seule URL forcee');
    $assert->is($WT->($tuned), 9,
        'mb639-818: une URL au timeout par defaut => budget worker 9s');

    my $slow = bless { conf => ConfV->new({ 'update.VERSION_TIMEOUT' => '12' }),
                       logger => LogV->new }, 'Mediabot';
    $assert->is($WT->($slow), 25,
        'mb639-818: deux URL x 12s + marge => budget worker 25s');

    my $bad = bless { conf => ConfV->new({ 'update.VERSION_URL' => 'pas-une-url' }),
                      logger => LogV->new }, 'Mediabot';
    # mb640: pour VERIFIER que les deux sources sont essayees, il faut que la
    # premiere ECHOUE. Avec la reponse en succes laissee par le cas precedent,
    # la boucle s'arretait a la premiere URL — et c'etait le bon comportement,
    # c'est l'attente du test qui etait fausse.
    my $saved_reply = $reply;
    $reply = { success => 0, status => 599, content => 'connect timeout' };
    @asked = (); $F->($bad);
    $assert->like($asked[0], qr{^https://},
        'mb638-818: une URL de conf invalide est ignoree');
    $assert->is(scalar @asked, 2,
        'mb639-818: URL invalide => les deux sources integrees restent actives');
    $reply = $saved_reply;

    # Un override HTTP explicite ne depend pas de IO::Socket::SSL.
    my $plain = bless { conf => ConfV->new({ 'update.VERSION_URL' => 'http://mirror.local/VERSION' }),
                        logger => LogV->new }, 'Mediabot';
    @asked = ();
    { local *HTTP::Tiny::can_ssl = sub { 0 };
      $reply = { success => 1, status => 200, content => "3.4dev-3\n" };
      my ($pv, $pw) = $F->($plain);
      $assert->is($pv, '3.4dev-3',
          'mb639-818: override HTTP explicite fonctionne sans support SSL');
      $assert->ok(!defined $pw && @asked == 1 && $asked[0] =~ m{^http://},
          'mb639-818: aucun fallback HTTPS n est tente avec override HTTP'); }

    # Une ancienne panne distante ne doit pas contaminer un check ou la
    # version locale est devenue illisible et ou aucun fetch n'est tente.
    {
        local *Mediabot::Helpers::getLocalVersion = sub { 'Undefined' };
        my $stale = bless {
            conf => ConfV->new,
            logger => LogV->new,
            _version_fetch_error => 'HTTP 599 (old failure)',
        }, 'Mediabot';
        Mediabot::Helpers::getVersion($stale);
        $assert->ok(!defined $stale->{_version_fetch_error},
            'mb639-818: une raison distante ancienne est effacee avant le check');
    }

    # [1] getVersion consomme LE MEME fetch (pas de seconde implementation)
    my $hsrc = do { open my $fh, '<:encoding(UTF-8)', 'Mediabot/Helpers.pm'
        or die $!; local $/; <$fh> };
    my ($gv) = $hsrc =~ /(sub getVersion \{.*?\n\}\n)/s;
    $assert->like($gv, qr/fetch_remote_version\(\$self\)/,
        'mb638-818: getVersion appelle le fetch factorise');
    $assert->ok($gv !~ /HTTP::Tiny->new/,
        'mb638-818: ... et ne refait plus la requete lui-meme');

    # [4] la raison traverse le tuyau
    $assert->like($hsrc, qr/encode_json\(\[\$local, \$remote, \$why\]\)/,
        'mb638-818: le fils embarque la raison dans le payload');
    $assert->like($hsrc, qr/\$callback->\(\$local, \$remote, \$reason\)/,
        'mb638-818: le parent la passe au callback');
    $assert->like($hsrc, qr/\$reason = 'version check timed out'/,
        'mb638-818: un depassement de delai a aussi sa raison');

    # [5] la commande l'affiche
    my @out;
    local *Mediabot::Helpers::botPrivmsg = sub { push @out, $_[2]; 1 };
    local *Mediabot::Helpers::botNotice  = sub { push @out, $_[2]; 1 };
    local *Mediabot::Helpers::logBot     = sub { 1 };
    local *Mediabot::Update::update_eligibility = sub { (1, undef) };
    local *Mediabot::Update::_spawn_updater     = sub { 1 };
    local *Mediabot::Helpers::getVersion_async = sub {
        $_[1]->('3.4dev-20260814_010040', 'Undefined', 'HTTP 599 (connect timeout)'); 1;
    };
    @out = ();
    Mediabot::Update::update_ctx(CtxV->new(bot => $bot, args => []));
    my $text = join "\n", @out;
    $assert->like($text, qr/GitHub version unavailable - HTTP 599 \(connect timeout\)/,
        'mb638-818: LA raison remplace « could not be determined »');
    $assert->like($text, qr/version sources?: https:/,
        'mb638-818: ... et le point de lecture est rappele');
    $assert->like($text, qr/conf update\.VERSION_URL/,
        'mb638-818: ... avec le moyen de le changer');

    # sans raison connue, le message historique reste
    local *Mediabot::Helpers::getVersion_async = sub {
        $_[1]->('3.4dev-1', 'Undefined', undef); 1;
    };
    @out = ();
    Mediabot::Update::update_ctx(CtxV->new(bot => $bot, args => []));
    $assert->like(join("\n", @out), qr/version could not be determined/,
        'mb638-818: sans raison connue, le message generique subsiste');

    # et le chemin nominal reste intact
    local *Mediabot::Helpers::getVersion_async = sub {
        $_[1]->('3.4dev-20260101_000000', '3.4dev-20260814_054627', undef); 1;
    };
    @out = ();
    Mediabot::Update::update_ctx(CtxV->new(bot => $bot, args => []));
    $assert->like(join("\n", @out), qr/An update is available/,
        'mb638-818: une vraie mise a jour est toujours annoncee');
};
