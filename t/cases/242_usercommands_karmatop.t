# t/cases/242_usercommands_karmatop.t
# Verify mbKarmaTop_ctx structure.
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
    my $src  = _slurp(File::Spec->catfile('.','Mediabot','UserCommands.pm'));
    my $body = _sub($src, 'mbKarmaTop_ctx');
    $assert->ok(defined $body, 'mbKarmaTop_ctx sub found');
    $assert->like($body // '', qr/KARMA/,
        'mbKarmaTop_ctx queries KARMA table');
    $assert->like($body // '', qr/ORDER BY.*score|score.*DESC/i,
        'mbKarmaTop_ctx orders by score descending');
    $assert->like($body // '', qr/LIMIT/,
        'mbKarmaTop_ctx uses LIMIT for top N');
    $assert->like($body // '', qr/->finish/,
        'mbKarmaTop_ctx calls ->finish');
    my $mm = _slurp(File::Spec->catfile('.','Mediabot','Mediabot.pm'));
    $assert->like($mm, qr/karmatop.*mbKarmaTop_ctx|mbKarmaTop_ctx/,
        'Mediabot.pm dispatches !karmatop');
    $assert->like($mm, qr/karmatop\|/,
        'Mediabot.pm has help entry for !karmatop');
};
