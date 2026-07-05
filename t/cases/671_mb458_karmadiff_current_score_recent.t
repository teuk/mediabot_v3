# t/cases/671_mb458_karmadiff_current_score_recent.t
# =============================================================================
# mb458/mb464 — !karmadiff : score courant déterministe ET du bon canal.
#
# mb458 supprimait la sélection par premier canal en ordre de hash. mb464 ferme
# deux angles restants : dans un canal, le score affiché doit provenir du même
# canal que le delta ; et deux entrées au même timestamp doivent être départagées
# de façon déterministe.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

sub _slurp_671 { my ($p)=@_; open my $fh,'<:encoding(UTF-8)',$p or die "$p: $!"; local $/; <$fh> }

sub _cs671 {
    my ($karma_log, $target, $channel) = @_;
    my @channels = sort { lc($a) cmp lc($b) || $a cmp $b } keys %$karma_log;
    @channels = grep { lc($_) eq lc($channel) } @channels
        if defined $channel && $channel ne '';
    my ($best, $best_ts, $best_channel, $best_index);
    for my $ch (@channels) {
        my $entries = $karma_log->{$ch} // [];
        for my $idx (0 .. $#$entries) {
            my $e = $entries->[$idx];
            next unless defined $e->{nick}
                     && lc($e->{nick}) eq lc($target)
                     && defined $e->{score};
            my $ts = $e->{ts} // 0;
            my $channel_key = lc($ch);
            if (!defined $best
                || $ts > $best_ts
                || ($ts == $best_ts && $channel_key gt $best_channel)
                || ($ts == $best_ts && $channel_key eq $best_channel && $idx > $best_index)) {
                ($best, $best_ts, $best_channel, $best_index) = ($e, $ts, $channel_key, $idx);
            }
        }
    }
    return defined $best ? $best->{score} : undef;
}

return sub {
    my ($assert) = @_;

    my $klog = {
        '#a' => [ { ts => 100, nick => 'bob', score => 3 } ],
        '#b' => [ { ts => 220, nick => 'Bob', score => 9 } ],
    };
    $assert->is(_cs671($klog, 'bob', '#a'), 3,
        'karmadiff en canal: score limité au même canal que le delta');
    $assert->is(_cs671($klog, 'bob', undef), 9,
        'karmadiff en privé: vue globale prend l’entrée la plus récente');
    $assert->ok(!defined _cs671($klog, 'ghost', '#a'),
        'nick sans entrée: score courant undef');

    my $tie = {
        '#a' => [ { ts => 500, nick => 'kai', score => 12 } ],
        '#b' => [ { ts => 500, nick => 'kai', score => 8  } ],
    };
    $assert->is(_cs671($tie, 'kai', undef), 8,
        'égalité de timestamp: départage de canal déterministe');

    my $src = _slurp_671(File::Spec->catfile('.', 'Mediabot', 'UserCommands.pm'));
    my ($blk) = $src =~ /(# CC11: fetch current score.*?my \$cur_score = _karma_current_score\(\$self, \$target, \$kd_chan\);)/s;
    $blk //= '';
    $assert->ok($blk ne '', 'bloc CC11 extrait');
    $assert->like($blk, qr/_karma_current_score\(\$self, \$target, \$kd_chan\)/,
        'karmadiff transmet le canal courant au helper');

    my $bad = () = $src =~ /grep \{ lc\(\$_->\{nick\}\) eq lc\(\$\w+\) \} reverse \@\$k?log\b[^;]*;\s*\n\s*if \([^)]*\{score\}[^)]*\) \{\s*\n[^\n]*; last;/g;
    $assert->is($bad, 0,
        'aucune sélection par premier canal arbitraire');
};
