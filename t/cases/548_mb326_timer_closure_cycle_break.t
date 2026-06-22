# t/cases/548_mb326_timer_closure_cycle_break.t
# =============================================================================
# mb326 — Rupture des cycles de référence closure<->timer (fuite mémoire).
#
# Plusieurs timers IO::Async::Timer::Countdown étaient créés selon le motif :
#
#     my $timer;
#     $timer = ...->new(on_expire => sub { ...  $timer ... });
#
# La closure on_expire capture le lexical $timer, et l'objet timer détient la
# closure : refcount jamais nul même après retrait du loop et des tableaux de
# suivi -> un objet timer fuit à chaque déclenchement. Sur un bot tournant des
# semaines (join/WHO, lignes de help, requêtes IA, complétions radio) cela
# s'accumule. Le correctif rompt le cycle avec `undef $timer` (et retire du loop
# là où ce n'était pas fait).
#
# Ce test :
#   1. reproduit le motif en isolation et prouve, via une sonde weaken, que
#      `undef $timer` libère bien l'objet alors que SANS lui il fuit ;
#   2. vérifie par scan de source que chaque site corrigé porte la rupture.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;
use Scalar::Util qw(weaken);

# Minimal stand-in for a one-shot timer that owns its on_expire coderef,
# mirroring how IO::Async::Timer::Countdown retains its callback.
{
    package T548::Timer;
    sub new { my ($c, %a) = @_; bless { %a }, $c }
    sub fire { my $self = shift; $self->{on_expire}->() if $self->{on_expire} }
}

sub _slurp_548 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    # --- 1a. Motif BUGGÉ : pas de undef -> l'objet fuit -------------------
    my $leak_probe;
    {
        my $timer;
        $timer = T548::Timer->new(
            on_expire => sub {
                # utilise $timer (capture) mais ne rompt pas le cycle
                my $ping = $timer ? 1 : 0;
            },
        );
        $leak_probe = $timer;
        weaken($leak_probe);
        $timer->fire;
        # on quitte le bloc : le lexical $timer disparaît, mais le cycle
        # closure<->timer maintient l'objet en vie.
    }
    $assert->ok(
        defined $leak_probe,
        'motif buggé (sans undef) : le timer fuit (cycle non rompu)'
    );

    # --- 1b. Motif CORRIGÉ : undef $timer -> l'objet est libéré ----------
    my $fixed_probe;
    {
        my $timer;
        $timer = T548::Timer->new(
            on_expire => sub {
                my $ping = $timer ? 1 : 0;
                undef $timer;          # rompt le cycle
            },
        );
        $fixed_probe = $timer;
        weaken($fixed_probe);
        $timer->fire;
    }
    $assert->ok(
        !defined $fixed_probe,
        'motif corrigé (undef $timer) : le timer est libéré (cycle rompu)'
    );

    # --- 2. Scan de source : chaque site corrigé porte la rupture ---------
    # Robuste : on vérifie la présence du tag mb326-B1 et d'un `undef $...timer;`
    # plutôt qu'un contexte exact (espaces/accents fragiles).
    my %checks = (
        'Mediabot/Mediabot.pm'        => [ qr/mb326-B1/, qr/undef \$who_timer;/, qr/undef \$timer;/ ],
        'Mediabot/External/Claude.pm' => [ qr/mb326-B1/, qr/undef \$timer;/ ],
        'Mediabot/UserCommands.pm'    => [ qr/mb326-B1/, qr/undef \$timer;/ ],
        'Mediabot/Radio/Request.pm'   => [ qr/mb326-B1/, qr/undef \$timer;/ ],
    );

    for my $rel (sort keys %checks) {
        my $src = _slurp_548(File::Spec->catfile('.', split m{/}, $rel));
        for my $re (@{ $checks{$rel} }) {
            $assert->like($src, $re, "$rel : rupture de cycle présente ($re)");
        }
    }
};
