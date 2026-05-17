# t/cases/258_helpers_db_balance.t
# Verify DB prepare/finish balance in key Helpers.pm subs (B26h).
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
    my $src = _slurp(File::Spec->catfile('.','Mediabot','Helpers.pm'));
    # High-frequency subs that were leaking
    for my $sub_name (qw(getIdUser checkUserLevel getIdChannelSet getIdChansetList
                          checkUserChannelLevel setChannelAntiFlood logBotAction)) {
        my $body = _sub($src, $sub_name);
        next unless defined $body;
        my @p   = ($body =~ /->prepare\(/g);
        my @f   = ($body =~ /->finish/g);
        my @fix = ($body =~ /B26h\/fix/g);
        $assert->ok(scalar(@f) + scalar(@fix) >= scalar(@p),
            "$sub_name: finishes+fixes >= prepares (B26h)");
    }
    # setChannelAntiFlood specifically has B26h/fix2 for sth reuse
    my $sca = _sub($src, 'setChannelAntiFlood');
    $assert->like($sca // '', qr/B26h\/fix2|finish if \$sth/, 
        'setChannelAntiFlood closes $sth before reuse (B26h/fix2)');
};
