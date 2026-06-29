# t/cases/582_mb363_liquidsoap_line_injection_guard.t
# =============================================================================
# mb363 — Une commande Liquidsoap Telnet doit rester sur une seule ligne.
#
# command() ajoutait "\nquit\n" à une chaîne fournie par les wrappers. Un CR/LF
# dans un chemin MP3 ou dans LIQUIDSOAP_QUEUE_ID pouvait donc injecter une
# deuxième commande avant quit. Le garde doit rejeter CR, LF et NUL avant même
# toute tentative de connexion, tout en conservant les commandes normales.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;
use Mediabot::Liquidsoap;

sub _slurp_582 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;

    my $liq = Mediabot::Liquidsoap->new(
        host     => '127.0.0.1',
        port     => 9,
        queue_id => 'mediabot_queue',
        timeout  => 1,
    );

    my $socket_attempts = 0;
    {
        no warnings 'redefine';
        local *IO::Socket::INET::new = sub {
            $socket_attempts++;
            die "network must not be reached for rejected commands\n";
        };

        my ($ok_lf, $err_lf) = $liq->command("mediabot_queue.queue\nserver.shutdown");
        $assert->ok(!$ok_lf, 'LF injection is rejected');
        $assert->like($err_lf, qr/unsafe Liquidsoap command/,
            'LF rejection returns an explicit error');

        my ($ok_cr, $err_cr) = $liq->command("mediabot_queue.queue\rserver.shutdown");
        $assert->ok(!$ok_cr, 'CR injection is rejected');
        $assert->like($err_cr, qr/CR, LF and NUL/,
            'CR rejection names the forbidden controls');

        my ($ok_nul, $err_nul) = $liq->command("mediabot_queue.push /tmp/a\x00.mp3");
        $assert->ok(!$ok_nul, 'NUL injection is rejected');
        $assert->like($err_nul, qr/CR, LF and NUL/,
            'NUL rejection uses the same central guard');

        my ($ok_uri, $err_uri) = $liq->push("/srv/radio/song.mp3\nmediabot_queue.skip");
        $assert->ok(!$ok_uri, 'push wrapper cannot bypass the line guard');
        $assert->like($err_uri, qr/unsafe Liquidsoap command/,
            'malicious URI is rejected by command()');

        my $bad_qid = Mediabot::Liquidsoap->new(
            host     => '127.0.0.1',
            port     => 9,
            queue_id => "mediabot_queue\nserver.shutdown",
            timeout  => 1,
        );
        my ($ok_qid, $err_qid) = $bad_qid->queue();
        $assert->ok(!$ok_qid, 'malicious queue id cannot inject another command');
        $assert->like($err_qid, qr/unsafe Liquidsoap command/,
            'queue-id injection is rejected centrally');
    }

    $assert->is($socket_attempts, 0,
        'all unsafe commands are rejected before opening a socket');

    my ($ok_empty, $err_empty) = $liq->command('');
    $assert->ok(!$ok_empty, 'empty-command guard remains active');
    $assert->is($err_empty, 'empty Liquidsoap command',
        'empty-command error remains unchanged');

    my $src = _slurp_582(File::Spec->catfile('.', 'Mediabot', 'Liquidsoap.pm'));
    $assert->like($src, qr/mb363-B1/,
        'tag mb363-B1 is present in Liquidsoap.pm');
    $assert->like($src, qr/if \$command =~ \/\[\\r\\n\\x00\]\//,
        'central command guard checks CR, LF and NUL');

    my $guard_pos  = index($src, q{if $command =~ /[\r\n\x00]/;});
    my $socket_pos = index($src, 'IO::Socket::INET->new(');
    $assert->ok($guard_pos >= 0 && $socket_pos > $guard_pos,
        'line-injection guard runs before socket creation');

    $assert->like($src,
        qr/my \$payload = \$command \. "\\nquit\\n";/,
        'normal protocol payload remains command plus quit');
};
