# t/cases/762_mb573_status_queues.t
# =============================================================================
# mb573 — .status devient le tableau de bord operateur : files flood (mb568),
# file achievements (mb558), dernier run d'archivage (mb571).
#   [1] fonctionnel (payload stubbe, stream collecteur) : les trois lignes
#       apparaissent dans chacun de leurs etats —
#       FloodQ empty / N deferred avec detail par canal et drapeau UNARMED ;
#       AchvQ empty / N pending ;
#       Archive disabled / enabled-no-run / worker running (pid) /
#       last run avec exit+duree (+signal seulement si non nul) ;
#   [2] discipline non-bloquante : le bloc mb573 ne contient AUCUN appel
#       dbh/prepare/execute/ensure_connected — etat memoire seulement ;
#   [3] le reap mb571 memorise _archive_last_run (at/exit/signal/elapsed) —
#       garde statique dans Mediabot.pm.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

use Mediabot::Partyline;

sub _slurp_762 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }

{
    package Stream762;
    sub new { bless { out => '' }, shift }
    sub write { $_[0]{out} .= $_[1]; 1 }
}

{
    package Conf762;
    sub new { my ($class, %kv) = @_; bless { %kv }, $class }
    sub get { my ($self, $k) = @_; return $self->{$k} }
}

{
    package Achv762;
    sub new { my ($class, $n) = @_; bless { n => $n }, $class }
    sub pending_check_count { $_[0]{n} }
}

sub _status_out_762 {
    my (%bot_fields) = @_;
    my $pl = bless { bot => { conf => Conf762->new, %bot_fields } }, 'Mediabot::Partyline';
    my $stream = Stream762->new;
    no warnings 'redefine';
    local *Mediabot::Partyline::_runtime_status_payload = sub {
        return { sessions => [], bot => { nick => 'mediabot', uptime => '1d' },
                 generated_at => 1000 };
    };
    $pl->_cmd_status($stream, 1);
    return $stream->{out};
}

return sub {
    my ($assert) = @_;

    # ------------------------------------------------------------------
    # [1] Les trois lignes, tous etats
    # ------------------------------------------------------------------
    {
        my $out = _status_out_762();
        $assert->like($out, qr/^FloodQ:   empty\r$/m, 'FloodQ vide');
        $assert->like($out, qr/^Archive:  disabled\r$/m, 'Archive desactive sans DBNAME');
        $assert->unlike($out, qr/AchvQ/, 'AchvQ absent sans module achievements');
    }
    {
        my $out = _status_out_762(
            _flood_outq => {
                '#quebec' => { items => [ 1, 2, 3, 4, 5 ], armed => 1 },
                '#miaw'   => { items => [ 1, 2 ],          armed => 0 },
                '#calm'   => { items => [],                armed => 0 },
            },
            achievements => Achv762->new(3),
        );
        $assert->like($out, qr/^FloodQ:   7 deferred \(#miaw:2 UNARMED, #quebec:5\)\r$/m,
            'FloodQ: total, detail trie par canal, drapeau UNARMED');
        $assert->like($out, qr/^AchvQ:    3 pending check\(s\)\r$/m, 'AchvQ: en attente');
    }
    {
        my $conf = Conf762->new('mysql.CHANNEL_LOG_ARCHIVE_DBNAME' => 'mediabot2');
        my $pl = bless { bot => { conf => $conf, achievements => Achv762->new(0) } },
            'Mediabot::Partyline';
        my $mk = sub {
            my (%extra) = @_;
            my $stream = Stream762->new;
            no warnings 'redefine';
            local *Mediabot::Partyline::_runtime_status_payload = sub {
                return { sessions => [], bot => {}, generated_at => 1000 };
            };
            $pl->{bot}{$_} = $extra{$_} for keys %extra;
            delete $pl->{bot}{$_} for grep { !exists $extra{$_} }
                ('_archive_last_run', '_channel_log_archive_pid');
            $pl->_cmd_status($stream, 1);
            return $stream->{out};
        };

        $assert->like($mk->(), qr/^Archive:  enabled, no run yet\r$/m,
            'Archive: active, aucun run');
        $assert->like($mk->(_channel_log_archive_pid => 4242),
            qr/^Archive:  worker running \(pid 4242\)\r$/m, 'Archive: worker en cours');
        $assert->like($mk->(
                _channel_log_archive_pid => 4242,
                _archive_last_run => { at => 900, exit => 0, signal => 0, elapsed => 8.0 },
            ),
            qr/^Archive:  worker running \(pid 4242\)\r$/m,
            'Archive: le worker courant prime sur le resultat precedent');
        $assert->like($mk->(_archive_last_run =>
                { at => 1000, exit => 0, signal => 0, elapsed => 12.34 }),
            qr/^Archive:  last run .* exit=0 in 12\.34s\r$/m,
            'Archive: dernier run ok sans mention de signal');
        $assert->like($mk->(_archive_last_run =>
                { at => 1000, exit => 3, signal => 9, elapsed => 1.5 }),
            qr/^Archive:  last run .* exit=3 in 1\.50s signal=9\r$/m,
            'Archive: echec avec signal affiche');
        $assert->like($mk->(), qr/^AchvQ:    empty\r$/m, 'AchvQ: vide');
    }

    # ------------------------------------------------------------------
    # [2] Discipline non-bloquante
    # ------------------------------------------------------------------
    {
        my $src = _slurp_762(File::Spec->catfile('Mediabot', 'Partyline.pm'))
            . "\n" . _slurp_762(File::Spec->catfile('Mediabot', 'Partyline', 'Commands.pm'));
        my ($block) = $src =~ /(# mb573-B1: operator observability.*?\n    \}\n)/s;
        $assert->ok(defined $block, 'bloc mb573 isole');
        $assert->unlike($block, qr/prepare|execute|ensure_connected|->dbh|selectrow/,
            'bloc mb573: etat memoire seulement, aucune requete');
    }

    # ------------------------------------------------------------------
    # [3] Le reap memorise le dernier run
    # ------------------------------------------------------------------
    {
        my $src = _slurp_762(File::Spec->catfile('Mediabot', 'Mediabot.pm'));
        $assert->like($src,
            qr/\{_archive_last_run\} = \{\n\s+at => time\(\), exit => \$exit, signal => \$signal,\n\s+elapsed => \$elapsed,/,
            'reap mb571: memorise at/exit/signal/elapsed');
    }
};
