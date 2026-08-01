# t/cases/779_mb596_partyline_throttle_hardening.t
# =============================================================================
# mb596 — durcissement du throttle partyline (anti-amplification + flood).
#   [1] limite inchangee : 10 lignes passent, la 11e recoit UN refus.
#   [2] anti-amplification : les lignes 12..29 sont ignorees EN SILENCE
#       (aucune nouvelle ecriture du refus), compteur silent_drops.
#   [3] flood caracterise : la 30e ligne deconnecte la session (message
#       « Flood protection », _close_session, users{id} disparu),
#       compteur flood_boots, log niveau 1.
#   [4] nouvelle fenetre = reprise propre (rate_warned reset).
#   [5] exemption pre-auth conservee (garde structurelle).
#   [6] .status affiche la ligne Throttle (memoire seule).
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }

{
    package Stream779;
    sub new { bless { out => '', close_when_empty => 0 }, shift }
    sub write { $_[0]{out} .= $_[1]; 1 }
    sub close_when_empty { $_[0]{close_when_empty}++; 1 }
    sub count779 { my ($s, $re) = @_; my $n = () = $s->{out} =~ /$re/g; $n }
}
{
    package Log779;
    sub new { bless { lines => [] }, shift }
    sub log { push @{ $_[0]{lines} }, [ $_[1], $_[2] ]; 1 }
}

sub _mk_779 {
    require Mediabot::Partyline;
    my $stream = Stream779->new;
    my $bot = { logger => Log779->new, metrics => undef };
    my $pl = bless {
        bot     => $bot,
        users   => { 7 => { authenticated => 1, login => 'teuk', level => 0 } },
        streams => { 7 => $stream },
    }, 'Mediabot::Partyline';
    return ($pl, $stream, $bot);
}

return sub {
    my ($assert) = @_;

    my ($pl, $stream, $bot) = _mk_779();

    # [1] 10 lignes passent, la 11e est refusee une fois
    $pl->_handle_line($stream, 7, ".nosuchcmd779") for 1..10;
    $assert->is($stream->count779(qr/Rate limit exceeded/), 0,
        'mb596-779: 10 lignes dans la fenetre — aucun refus');
    $pl->_handle_line($stream, 7, ".nosuchcmd779");
    $assert->is($stream->count779(qr/Rate limit exceeded/), 1,
        'mb596-779: la 11e ligne recoit le refus');
    $assert->is($pl->{_rate_stats}{hits}, 1, 'mb596-779: compteur hits');

    # [2] les suivantes sont silencieuses
    $pl->_handle_line($stream, 7, ".nosuchcmd779") for 12..29;
    $assert->is($stream->count779(qr/Rate limit exceeded/), 1,
        'mb596-779: anti-amplification — le refus reste unique');
    $assert->is($pl->{_rate_stats}{silent_drops}, 18,
        'mb596-779: drops silencieux comptes');
    $assert->ok(exists $pl->{users}{7}, 'mb596-779: session toujours vivante a 29');

    # [3] la 30e deconnecte
    $pl->_handle_line($stream, 7, ".nosuchcmd779");
    $assert->is($stream->count779(qr/Flood protection: disconnecting/), 1,
        'mb596-779: flood boot annonce');
    $assert->ok(!exists $pl->{users}{7}, 'mb596-779: session fermee au flood');
    $assert->is($stream->{close_when_empty}, 1,
        'mb597-779: le transport est reellement ferme apres le message');
    $assert->is($pl->{_rate_stats}{flood_boots}, 1, 'mb596-779: compteur boots');
    $assert->ok((grep { $_->[0] == 1 && $_->[1] =~ /flood protection boot.*login=teuk.*30 lines/ }
        @{ $bot->{logger}{lines} }), 'mb596-779: boot logge niveau 1');

    # [4] nouvelle fenetre = reprise
    my ($pl2, $stream2) = _mk_779();
    $pl2->_handle_line($stream2, 7, ".x") for 1..11;
    $assert->is($stream2->count779(qr/Rate limit exceeded/), 1,
        'mb596-779: fenetre 1 — refus pose');
    $pl2->{users}{7}{rate_window} = time() - 6;   # la fenetre expire
    $pl2->_handle_line($stream2, 7, ".x");
    $assert->is($pl2->{users}{7}{rate_count}, 1,
        'mb596-779: nouvelle fenetre — compteur reparti');
    $assert->is($pl2->{users}{7}{rate_warned}, 0,
        'mb596-779: nouvelle fenetre — rate_warned reset');
    $pl2->_handle_line($stream2, 7, ".x") for 2..11;
    $assert->is($stream2->count779(qr/Rate limit exceeded/), 2,
        'mb596-779: le refus peut se reposer dans la fenetre suivante');

    # [5] + [6] gardes structurelles
    my $src = do { open my $fh, '<:encoding(UTF-8)', 'Mediabot/Partyline.pm' or die $!; local $/; <$fh> };
    $assert->like($src, qr/Exempted during authentication/,
        'mb596-779: exemption pre-auth conservee');
    my ($throttle_sec) = $src =~ /(# mb596-B1: sante du throttle.*?flood boot\(s\).*?\n.*?\})/s;
    $assert->ok(defined $throttle_sec, 'mb596-779: ligne Throttle au .status');
    $assert->ok(($throttle_sec // 'dbh') !~ /dbh|->do\(|prepare\(|\bkill\b/,
        'mb596-779: ligne Throttle memoire seule (contrat mb573)');
};
