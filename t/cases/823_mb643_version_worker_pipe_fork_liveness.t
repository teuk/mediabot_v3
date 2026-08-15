# t/cases/823_mb643_version_worker_pipe_fork_liveness.t
# =============================================================================
# mb643 — le worker de version doit utiliser un pipe/fork explicite avec
# IO::Async::watch_process(), jamais le piped-open Perl '-|'. Un backstop de
# finalisation doit aussi garantir qu'un timeout ne peut pas pendre l'IRC.
# =============================================================================

use strict;
use warnings;
use utf8;

sub _slurp_823 {
    my ($p) = @_;
    open my $fh, '<:encoding(UTF-8)', $p or die "$p: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    my $src = _slurp_823('Mediabot/Helpers.pm');
    my ($async) = $src =~ /(sub getVersion_async \{.*?\n\}\n# getDetailedVersion)/s;

    $assert->ok(defined $async,
        'mb643-823: getVersion_async localisee');

    $assert->like($async // '',
        qr/explicit pipe \+ fork, matching the proven Achievements worker/,
        'mb643-823: la cause et le pattern de reference sont documentes');

    $assert->like($async // '',
        qr/pipe\(\$pipe,\s*\$child_write\)/,
        'mb643-823: pipe explicite');

    $assert->like($async // '',
        qr/my \$child_pid = fork\(\)/,
        'mb643-823: fork explicite');

    my $exec = $async // '';
    $exec =~ s/#.*$//mg;

    $assert->unlike($exec,
        qr/open\s*\([^;\n]*['"]-\|['"]/,
        'mb643-823: aucun piped-open Perl ne subsiste');

    $assert->like($async // '',
        qr/if \(\$child_pid == 0\) \{\s*eval \{ close \$pipe \}/s,
        'mb643-823: le fils ferme le cote lecture');

    $assert->like($async // '',
        qr/binmode\(\$child_write,\s*':raw'\)/,
        'mb643-823: le fils utilise le descripteur d ecriture dedie');

    $assert->like($async // '',
        qr/syswrite\(\s*\$child_write,/s,
        'mb643-823: le payload JSON est ecrit dans le pipe dedie');

    $assert->like($async // '',
        qr/eval \{ close \$child_write \};\s*\n\s*POSIX::_exit\(0\)/s,
        'mb643-823: le fils ferme son writer avant _exit');

    $assert->like($async // '',
        qr/\n\s*eval \{ close \$child_write \};\s*\n\s*\n\s*my \$state/s,
        'mb643-823: le parent ferme immediatement son writer');

    $assert->like($async // '',
        qr/\$loop->watch_process\(\s*\$child_pid/s,
        'mb643-823: IO::Async reste proprietaire du PID');

    $assert->unlike($exec,
        qr/\bwaitpid\s*\(/,
        'mb643-823: aucun waitpid manuel');

    $assert->like($async // '',
        qr/force\s*=>\s*0/,
        'mb643-823: etat de finalisation forcee present');

    $assert->like($async // '',
        qr/my \(\$stream,\s*\$timeout_timer,\s*\$kill_timer,\s*\$force_timer\)/,
        'mb643-823: timer de liveness distinct');

    $assert->like($async // '',
        qr/\$state->\{force\}\s*\|\|\s*\(\$state->\{child_done\}/s,
        'mb643-823: le backstop peut debloquer finish');

    $assert->like($async // '',
        qr/\$remove_timer->\(\$force_timer\)/,
        'mb643-823: le backstop est nettoye a la finalisation');

    $assert->like($async // '',
        qr/\$force_timer\s*=\s*IO::Async::Timer::Countdown->new/,
        'mb643-823: backstop de liveness cree');

    $assert->like($async // '',
        qr/\$force_timer\s*=\s*IO::Async::Timer::Countdown->new\(.*?
           delay\s*=>\s*2,/sx,
        'mb643-823: backstop arme deux secondes apres timeout');

    $assert->like($async // '',
        qr/\$state->\{force\}\s*=\s*1;\s*
           \$finish->\(\)\s+if\s+\$finish;/sx,
        'mb643-823: expiration force la finalisation');

    $assert->like($async // '',
        qr/kill 'TERM', \$child_pid/,
        'mb643-823: TERM conserve');

    $assert->like($async // '',
        qr/kill 'KILL', \$child_pid/,
        'mb643-823: KILL conserve');

    $assert->like($async // '',
        qr/\$finish->\(\)\s+if\s+\$finish/,
        'mb643-823: callbacks tardifs proteges apres finalisation');

    $assert->unlike($exec,
        qr/binmode\s*\(\s*STDOUT|syswrite\s*\(\s*STDOUT/,
        'mb643-823: le worker ne detourne plus STDOUT pour son IPC');
};
