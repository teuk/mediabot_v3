# t/cases/577_mb358_get_int_diagnostics.t
# =============================================================================
# mb358 — Diagnostics utiles et non-spammy pour get_int.
#
# get_int (mb354) retombait sur le défaut (valeur malformée) et clampait
# (hors bornes) SILENCIEUSEMENT : une erreur de config passait inaperçue.
# mb358 émet un diagnostic quand une valeur PRÉSENTE est malformée ou clampée,
# avec déduplication par signature (clé|type|valeur) pour ne pas spammer
# (get_int peut être appelé à chaque login/tick). L'absence de clé reste
# silencieuse (get() la trace déjà en debug) et les valeurs de retour sont
# inchangées (cf. test 573).
# =============================================================================

use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);

BEGIN {
    unshift @INC, "$Bin/../..";
    package Config::Simple;
    sub import { }
    sub new { bless {}, shift }
    sub vars { return () }
    sub param { return 1 }
    sub write { return 1 }
    $INC{'Config/Simple.pm'} = __FILE__;
}

require Mediabot::Conf;

# Logger capteur : enregistre (level, message).
{
    package TestLogger;
    sub new { bless { events => [] }, shift }
    sub log { my ($self, $level, $msg) = @_; push @{ $self->{events} }, [ $level, $msg ]; }
    sub can { my ($self, $m) = @_; return $m eq 'log' ? \&log : undef; }
}

my $conf = Mediabot::Conf->new({
    'main.OK'     => '42',
    'main.BAD'    => '12x',
    'main.BAD2'   => 'oops',
    'main.LOW'    => '-50',
    'main.HIGH'   => '99999',
    'main.DEDUP'  => '7x',
    'main.DEDUPC' => '77777',
});
my $log = TestLogger->new;
$conf->set_logger($log);

sub diag_events { grep { $_->[1] =~ /^Conf: / } @{ $log->{events} } }
sub clear_events { @{ $log->{events} } = (); }

# --- 1. Valeur correcte : aucun diagnostic ---------------------------------
is($conf->get_int('main.OK', default => 7, min => 0, max => 100), 42, 'OK: valeur correcte');
is(scalar(diag_events()), 0, 'OK: aucun diagnostic émis');

# --- 2. Valeur malformée : 1 diagnostic, retour = défaut -------------------
clear_events();
is($conf->get_int('main.BAD', default => 7, min => 0, max => 100), 7, 'BAD: retombe sur le défaut');
my @bad = diag_events();
is(scalar(@bad), 1, 'BAD: un diagnostic émis');
like($bad[0][1], qr/is not an integer/, 'BAD: message explicite');
is($bad[0][0], 2, 'BAD: niveau de log = 2 (notice)');

# --- 3. Déduplication : même valeur relue 5x -> toujours 1 diagnostic -------
clear_events();
$conf->get_int('main.DEDUP', default => 7) for 1 .. 5;
is(scalar(diag_events()), 1, 'dédup: 5 lectures de la même valeur fautive -> 1 seul log');

# --- 4. Une AUTRE valeur fautive re-déclenche un diagnostic ----------------
clear_events();
$conf->get_int('main.BAD2', default => 7);
is(scalar(diag_events()), 1, 'autre clé/valeur fautive -> nouveau diagnostic');

# --- 5. Clamp bas et haut : diagnostic + valeur clampée --------------------
clear_events();
is($conf->get_int('main.LOW', default => 7, min => 0, max => 100), 0, 'LOW: clampé au min');
my @low = diag_events();
is(scalar(@low), 1, 'LOW: un diagnostic');
like($low[0][1], qr/below minimum 0; clamped to 0/, 'LOW: message de clamp bas');

clear_events();
is($conf->get_int('main.HIGH', default => 7, min => 0, max => 100), 100, 'HIGH: clampé au max');
my @high = diag_events();
is(scalar(@high), 1, 'HIGH: un diagnostic');
like($high[0][1], qr/above maximum 100; clamped to 100/, 'HIGH: message de clamp haut');

# --- 6. Clamp dédupliqué ---------------------------------------------------
clear_events();
$conf->get_int('main.DEDUPC', default => 7, min => 0, max => 100) for 1 .. 4;
is(scalar(diag_events()), 1, 'dédup clamp: 4 lectures -> 1 log');

# --- 7. Clé absente : silencieux côté get_int (pas de diag clamp/malformed) -
clear_events();
is($conf->get_int('main.MISSING', default => 9, min => 0, max => 100), 9, 'MISSING: défaut');
is(scalar(diag_events()), 0, 'MISSING: pas de diagnostic get_int (clé absente = normal)');

# --- 8. Sans logger : aucune erreur, valeurs correctes ---------------------
my $conf2 = Mediabot::Conf->new({ 'main.BAD' => 'zzz', 'main.HIGH' => '9999' });
is($conf2->get_int('main.BAD',  default => 3, min => 0, max => 10), 3,  'sans logger: malformé -> défaut');
is($conf2->get_int('main.HIGH', default => 3, min => 0, max => 10), 10, 'sans logger: clampé sans crash');

# --- 9. Source : diagnostics + dédup présents ------------------------------
sub slurp { my ($p) = @_; open my $fh, '<:encoding(UTF-8)', $p or die $!; local $/; <$fh> }
my $src = slurp('Mediabot/Conf.pm');
like($src, qr/sub _get_int_diag/,        'helper de diagnostic présent');
like($src, qr/_get_int_diag_seen/,       'déduplication par signature présente');
like($src, qr/mb358-B1/,                 'tag mb358-B1 présent');

done_testing();
