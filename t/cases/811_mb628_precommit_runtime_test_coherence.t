# t/cases/811_mb628_precommit_runtime_test_coherence.t
use strict;
use warnings;
use utf8;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;
use File::Glob qw(bsd_glob);

sub _slurp_811 {
    my ($p) = @_;
    open my $fh, '<:encoding(UTF-8)', $p or die "$p: $!";
    local $/;
    return <$fh>;
}

return sub {
    my ($assert) = @_;
    my $claude = _slurp_811(File::Spec->catfile('.', 'Mediabot', 'External', 'Claude.pm'));
    my $social = _slurp_811(File::Spec->catfile('.', 'Mediabot', 'SocialHistory.pm'));
    my $t709   = _slurp_811(File::Spec->catfile('.', 't', 'cases', '709_mb499_onthisday_date.t'));

    $assert->like($social, qr/my \$day_range_sql = "ts >= \$day_range_expr AND ts < \$day_range_expr \+ INTERVAL 1 DAY";/,
        'mb628-811: runtime onthisday porte la plage sargable dans SocialHistory');
    $assert->like($t709, qr/top-talker utilise une plage de journée indexable/,
        'mb628-811: le test 709 attend maintenant la plage indexable');
    $assert->ok($t709 !~ /top-talker aussi paramétré/,
        'mb628-811: l ancienne attente MONTH\/DAY du top-talker a disparu');
    $assert->like($t709, qr/id \+ deux fois \(year,month,day\)/,
        'mb628-811: le test 709 verrouille aussi l arite des binds');

    $assert->like($claude, qr/unless \(defined \$n_total\) \{\s*Mediabot::Helpers::botNotice\(\$self, \$nick, 'DB error\.'\);\s*return;/s,
        'mb628-811: echec du COUNT => fail-closed');
    $assert->like($claude, qr/my \$win_start_op\s*=\s*\(defined \$period && \$period eq 'last' && \$summary_last_ts > 0\)\s*\? '>' : '>=';/s,
        'mb628-811: last choisit >, les autres periodes >=');
    $assert->like($claude, qr/AND cl\.ts \$win_start_op \$win_start AND cl\.ts < \$win_end/,
        'mb628-811: le COUNT applique l operateur de borne');
    $assert->like($claude, qr/my \$op = \(\$i == 0\) \? \$win_start_op : '>=';/,
        'mb628-811: seule la premiere tranche reprend la borne stricte');

    my %seen;
    my @dups;
    for my $path (bsd_glob(File::Spec->catfile('.', 't', 'cases', '*.t'))) {
        my ($base) = $path =~ m{([^/\\]+)$};
        next unless defined $base && $base =~ /^(\d+)_/;
        my $num = $1;
        next if $num < 790;
        push @dups, "$num:$base/$seen{$num}" if exists $seen{$num};
        $seen{$num} = $base;
    }
    $assert->is(scalar @dups, 0, 'mb628-811: numeros de tests recents uniques');
};
