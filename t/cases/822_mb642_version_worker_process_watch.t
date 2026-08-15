# t/cases/822_mb642_version_worker_process_watch.t
# =============================================================================
# mb642 — IO::Async doit etre l'unique proprietaire de la collecte du worker
# de version. Un waitpid() manuel concurrence SIGCHLD/watch_process et peut
# transformer un worker termine avec succes en faux "could not be reaped".
# =============================================================================

use strict;
use warnings;
use utf8;
use File::Spec;

sub _slurp_822 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_822 {
    my ($src, $name) = @_;
    my $re = qr/^sub\s+\Q$name\E\s*\{/m;
    return undef unless $src =~ /$re/g;

    my ($start, $pos, $depth) = ($-[0], pos($src), 1);
    my ($quote, $escape, $comment);
    while ($pos < length($src)) {
        my $ch = substr($src, $pos, 1);

        if ($comment) {
            $comment = 0 if $ch eq "\n";
            $pos++;
            next;
        }
        if (defined $quote) {
            if ($escape) { $escape = 0; $pos++; next; }
            if ($ch eq '\\') { $escape = 1; $pos++; next; }
            if ($ch eq $quote) { undef $quote; $pos++; next; }
            $pos++;
            next;
        }

        if ($ch eq '#') { $comment = 1; $pos++; next; }
        if ($ch eq "'" || $ch eq '"') { $quote = $ch; $pos++; next; }
        $depth++ if $ch eq '{';
        $depth-- if $ch eq '}';
        return substr($src, $start, $pos + 1 - $start) if $depth == 0;
        $pos++;
    }

    return undef;
}

return sub {
    my ($assert) = @_;

    my $hsrc = _slurp_822(File::Spec->catfile('.', 'Mediabot', 'Helpers.pm'));
    my $usrc = _slurp_822(File::Spec->catfile('.', 'Mediabot', 'Update.pm'));
    my $async = _extract_822($hsrc, 'getVersion_async');

    $assert->ok(defined $async,
        'mb642-822: getVersion_async localisee');

    $assert->like($async // '',
        qr/IO::Async owns SIGCHLD\/process collection/,
        'mb642-822: la cause de la course de reap est documentee');

    $assert->like($async // '',
        qr/\$loop->can\('watch_process'\)/,
        'mb642-822: la capacite process watcher est verifiee avant fork');

    $assert->like($async // '',
        qr/\$loop->watch_process\(\s*\$child_pid/s,
        'mb642-822: le PID est confie a IO::Async');

    $assert->like($async // '',
        qr/my \(\$pid, \$wait_status\) = \@_/,
        'mb642-822: le watcher recoit le statut brut');

    $assert->like($async // '',
        qr/\$state->\{wait_status\}\s*=\s*\$wait_status/,
        'mb642-822: le statut du watcher est conserve');

    my $exec = $async // '';
    $exec =~ s/#.*$//mg;

    $assert->unlike($exec,
        qr/\bwaitpid\s*\(/,
        'mb642-822: aucun waitpid manuel ne concurrence IO::Async');

    $assert->unlike($exec,
        qr/\bWNOHANG\b/,
        'mb642-822: aucun polling WNOHANG ne subsiste');

    $assert->unlike($exec,
        qr/wait_failed/,
        'mb642-822: le faux etat wait_failed disparait');

    $assert->like($async // '',
        qr/version check worker setup failed:/,
        'mb642-822: un watcher impossible produit une raison');

    $assert->like($async // '',
        qr/kill 'TERM', \$child_pid/,
        'mb642-822: timeout envoie toujours TERM');

    $assert->like($async // '',
        qr/kill 'KILL', \$child_pid/,
        'mb642-822: timeout escalade toujours en KILL');

    $assert->like($async // '',
        qr/if \(\$eof && !\$state->\{pipe_eof\}\+\+\).*?\$finish->\(\)/s,
        'mb642-822: EOF reveille la finalisation sans reap manuel');

    $assert->like($usrc,
        qr/set conf update\.VERSION_URL to override/,
        'mb642-822: le diagnostic explique comment activer un override');

    $assert->unlike($usrc,
        qr/\(override: conf update\.VERSION_URL\)/,
        'mb642-822: les URL par defaut ne sont plus etiquetees override');
};
