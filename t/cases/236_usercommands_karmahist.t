# t/cases/236_usercommands_karmahist.t
# =============================================================================
# Verify !karmahist and karma log ring buffer in processKarma (I4).
# =============================================================================
use strict; use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;
sub _slurp { open my $fh,'<:encoding(UTF-8)',$_[0] or die $!; local $/; <$fh> }
sub _sub { my($s,$n)=@_; my $re=qr/^[ \t]*sub[ \t]+\Q$n\E\b[^{]*\{/m;
    return undef unless $s=~/$re/g; my($st,$p,$d)=($-[0],pos($s),1);
    while($p<length($s)){my $c=substr($s,$p,1);$d++ if $c eq '{';$d-- if $c eq '}';
    return substr($s,$st,$p+1-$st) if $d==0; $p++} undef }
return sub {
    my ($assert) = @_;
    my $src = _slurp(File::Spec->catfile('.', 'Mediabot', 'UserCommands.pm'));

    # processKarma log
    my $pk = _sub($src, 'processKarma');
    $assert->ok(defined $pk, 'processKarma body found');
    $assert->like($pk // '', qr/I4.*karma log|karma log.*I4/i,
        'processKarma has I4 karma log comment');
    $assert->like($pk // '', qr/_karma_log/,
        'processKarma appends to _karma_log');
    $assert->like($pk // '', qr/splice.*karma_log.*20|20.*karma_log/,
        'processKarma caps ring buffer at 20 entries');
    $assert->like($pk // '', qr/ts.*time\(\)|time\(\).*ts/,
        'processKarma stores timestamp in log entry');
    $assert->like($pk // '', qr/from.*nick|nick.*from/,
        'processKarma stores the triggering nick (from)');

    # mbKarmaHist_ctx
    my $kh = _sub($src, 'mbKarmaHist_ctx');
    $assert->ok(defined $kh, 'mbKarmaHist_ctx body found');
    $assert->like($kh // '', qr/_karma_log/,
        'mbKarmaHist_ctx reads from _karma_log');
    $assert->like($kh // '', qr/reverse/,
        'mbKarmaHist_ctx shows most recent first');
    $assert->like($kh // '', qr/5/,
        'mbKarmaHist_ctx limits output to 5 entries');
    $assert->like($kh // '', qr/filter|lc.*nick/,
        'mbKarmaHist_ctx supports optional nick filter');
    $assert->like($kh // '', qr/ago/,
        'mbKarmaHist_ctx shows human-readable time ago');

    # Dispatch
    my $mm = _slurp(File::Spec->catfile('.', 'Mediabot', 'Mediabot.pm'));
    $assert->like($mm, qr/karmahist.*mbKarmaHist_ctx|mbKarmaHist_ctx.*karmahist/,
        'Mediabot.pm dispatches !karmahist to mbKarmaHist_ctx');
    $assert->like($mm, qr/karmahist\|/,
        'Mediabot.pm has help entry for !karmahist');
};
