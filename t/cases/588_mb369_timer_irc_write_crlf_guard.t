# t/cases/588_mb369_timer_irc_write_crlf_guard.t
# =============================================================================
# mb369 — Les commandes de TIMER ne peuvent plus injecter de lignes IRC.
#
# onStartTimers() et mbAddTimer_ctx() envoyaient la commande d'un timer en IRC
# brut : $self->{irc}->write("$cmd\x0d\x0a"). La commande vient de la table
# TIMERS, potentiellement alimentée hors du flux IRC normal (édition directe,
# import, restauration). Une commande contenant CR/LF/NUL aurait injecté des
# commandes IRC supplémentaires à CHAQUE tick.
#
# mb369 centralise l'écriture dans _timer_irc_write(), qui refuse CR/LF/NUL
# (défense en profondeur, cf. botPrivmsg mb344 / Liquidsoap mb363). La commande
# raw volontaire ".dump" (dumpCmd_ctx) reste inchangée (args IRC déjà mono-ligne).
#
# Validation : (a) sémantique du garde-fou, (b) scan de source du câblage.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

# Reproduction du prédicat de refus de _timer_irc_write.
sub _would_send {
    my ($cmd) = @_;
    return 0 unless defined $cmd;
    return 0 if $cmd =~ /[\r\n\x00]/;   # CR / LF / NUL -> refus
    return 1;
}

sub _slurp_588 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    # --- 1. Sémantique du garde-fou --------------------------------------
    $assert->ok(_would_send('PRIVMSG #chan :hello'),       'commande mono-ligne normale -> envoyée');
    $assert->ok(_would_send('TOPIC #chan :nouveau topic'), 'autre commande normale -> envoyée');
    $assert->ok(!_would_send("PRIVMSG #c :hi\r\nJOIN #evil"), 'CRLF -> refusée');
    $assert->ok(!_would_send("PRIVMSG #c :hi\nQUIT"),         'LF -> refusée');
    $assert->ok(!_would_send("FOO\rBAR"),                     'CR -> refusée');
    $assert->ok(!_would_send("FOO\x00BAR"),                   'NUL -> refusée');
    $assert->ok(!_would_send(undef),                          'undef -> refusée');

    # --- 2. Scan source : helper + câblage -------------------------------
    my $src = _slurp_588(File::Spec->catfile('.', 'Mediabot', 'DBCommands.pm'));

    my ($helper) = $src =~ /(sub _timer_irc_write \{.*?\n\}\n)/s; $helper //= '';
    $assert->ok($helper ne '', 'helper _timer_irc_write défini');
    $assert->like($helper, qr/\[\\r\\n\\x00\]/, 'helper refuse CR/LF/NUL');
    $assert->like($helper, qr/is_connected/,     'helper vérifie la connexion');

    # Les deux on_tick de timer passent par le helper (et plus par un write brut).
    my $n_calls = () = $src =~ /\$self->_timer_irc_write\(/g;
    $assert->ok($n_calls >= 2, 'les 2 timers (onStartTimers + mbAddTimer) utilisent le helper');

    # onStartTimers / mbAddTimer_ctx ne contiennent plus d'écriture brute de la
    # commande de timer.
    my ($onstart) = $src =~ /(sub onStartTimers \{.*?\n\}\n)/s;   $onstart //= '';
    my ($addtimer) = $src =~ /(sub mbAddTimer_ctx \{.*?\n\}\n)/s; $addtimer //= '';
    $assert->unlike($onstart,  qr/\{irc\}->write\("\$command\\x0d/, 'onStartTimers: plus de write brut');
    $assert->unlike($addtimer, qr/\{irc\}->write\("\$cmd\\x0d/,     'mbAddTimer_ctx: plus de write brut');

    # La commande raw volontaire .dump (dumpCmd_ctx) garde son write direct.
    my ($dump) = $src =~ /(sub dumpCmd_ctx \{.*?\n\}\n)/s; $dump //= '';
    $assert->like($dump, qr/\{irc\}->write\("\$cmd\\x0d/,
                  'dumpCmd_ctx (.dump): write direct préservé (outil raw volontaire)');

    $assert->like($src, qr/mb369-B1/, 'tag mb369-B1 présent');
};
