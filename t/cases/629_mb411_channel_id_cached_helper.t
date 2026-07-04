# t/cases/629_mb411_channel_id_cached_helper.t
# =============================================================================
# mb411 — Helper central channel_id_cached() : cache interne d'abord (clé lc,
# mb407), SELECT en repli. Trois handlers convertis ce round (karma reset,
# trivia top, trivia score reset) ; les autres occurrences du motif recopié
# seront migrées progressivement.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

sub _slurp_629 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }

return sub {
    my ($assert) = @_;

    # --- 1. Le helper, exécuté en réel -------------------------------------
    require Mediabot::Helpers;
    $assert->ok(Mediabot::Helpers->can('channel_id_cached'), 'helper défini');

    # objet Channel minimal + bot minimal (pas de DB nécessaire : cache hit).
    { package T629::Chan; sub new { bless { id => $_[1] }, $_[0] } sub get_id { $_[0]{id} } }
    my $bot = { channels => { '#teuk' => T629::Chan->new(42) }, dbh => undef };

    $assert->is(Mediabot::Helpers::channel_id_cached($bot, '#teuk'), 42, 'cache hit (casse exacte)');
    $assert->is(Mediabot::Helpers::channel_id_cached($bot, '#TeUk'), 42, 'cache hit (casse libre, clé lc)');
    $assert->ok(!defined Mediabot::Helpers::channel_id_cached($bot, ''),    'canal vide -> undef');
    $assert->ok(!defined Mediabot::Helpers::channel_id_cached($bot, undef), 'undef -> undef');

    # mb416-B3: un cache miss utilise le handle ACTUEL de Mediabot::DB, pas le
    # handle de compatibilité potentiellement périmé dans $bot->{dbh}.
    {
        package T629::STH;
        sub new { bless { id => $_[1] }, $_[0] }
        sub execute { 1 }
        sub fetchrow_hashref { { id_channel => $_[0]{id} } }
        sub finish { 1 }
        package T629::DBH;
        sub new { bless { id => $_[1], prepares => 0 }, $_[0] }
        sub prepare { $_[0]{prepares}++; T629::STH->new($_[0]{id}) }
        package T629::DB;
        sub new { bless { dbh => $_[1], calls => 0 }, $_[0] }
        sub ensure_connected { $_[0]{calls}++; $_[0]{dbh} }
        package T629::Stale;
        sub prepare { die 'stale compatibility handle used' }
    }
    my $fresh_dbh = T629::DBH->new(77);
    my $db_wrap   = T629::DB->new($fresh_dbh);
    my $fallback_bot = {
        channels => {}, db => $db_wrap, dbh => bless({}, 'T629::Stale'),
    };
    $assert->is(Mediabot::Helpers::channel_id_cached($fallback_bot, '#fallback'), 77,
        'cache miss utilise le handle reconnecté');
    $assert->is($db_wrap->{calls}, 1, 'ensure_connected appelé une fois sur cache miss');
    $assert->ok(!defined Mediabot::Helpers::channel_id_cached({ channels => {} }, '#missing'),
        'cache miss sans DB -> undef, sans exception');

    # --- 2. Le helper est exporté ------------------------------------------
    my $h = _slurp_629(File::Spec->catfile('.', 'Mediabot', 'Helpers.pm'));
    $assert->like($h, qr/^\s+channel_id_cached$/m, 'présent dans @EXPORT');
    my ($body) = $h =~ /(sub channel_id_cached \{.*?\n\}\n)/s; $body //= '';
    $assert->like($body, qr/\{channels\}\{lc \$channel\}/, 'cache interne consulté d\'abord');
    $assert->like($body, qr/SELECT id_channel FROM CHANNEL WHERE name = \?/, 'SELECT en repli');
    $assert->like($body, qr/ensure_connected/, 'fallback utilise le handle DB courant (mb416)');

    (my $h_code = $h) =~ s/^\s*#.*$//mg;
    my $nhsel = () = $h_code =~ /SELECT id_channel FROM CHANNEL WHERE name/g;
    $assert->is($nhsel, 1,
        'Helpers: seul le SELECT de repli du helper subsiste');
    my ($log_body) = $h =~ /(sub logBotAction \{.*?
\}
)/s; $log_body //= '';
    $assert->like($log_body, qr/channel_id_cached\(\$self, \$sChannel\)/,
        'logBotAction utilise le cache au lieu d un SELECT par événement');

    # --- 3. Les 3 sites convertis + budget de migration ---------------------
    my $uc = _slurp_629(File::Spec->catfile('.', 'Mediabot', 'UserCommands.pm'));
    my $ncalls = () = $uc =~ /Mediabot::Helpers::channel_id_cached\(/g;
    $assert->ok($ncalls >= 3, 'au moins 3 handlers convertis au helper');
    my $nsel = () = $uc =~ /SELECT id_channel FROM CHANNEL WHERE name/g;
    $assert->is($nsel, 2, "migration UserCommands terminée: seuls les 2 replis mb410 restent (actuel: $nsel, mb414)");

    # mb412: le lot Partyline est intégralement migré — verrouillé à zéro.
    my $pl = _slurp_629(File::Spec->catfile('.', 'Mediabot', 'Partyline.pm'));
    my $npl = () = $pl =~ /SELECT id_channel FROM CHANNEL WHERE name/g;
    $assert->is($npl, 0, 'Partyline: plus aucun SELECT id_channel par nom (mb412)');
    my $nplcalls = () = $pl =~ /Mediabot::Helpers::channel_id_cached\(/g;
    $assert->ok($nplcalls >= 4, 'Partyline: les 4 sites utilisent le helper');

    $assert->like($h, qr/mb411-R1/, 'tag mb411-R1');
    $assert->like($h, qr/mb416-B3/, 'tag mb416-B3');
};
