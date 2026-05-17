# t/cases/256_channelcommands_db_balance.t
# Verify DB prepare/finish balance in key ChannelCommands.pm subs (B26cc).
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
    my $src = _slurp(File::Spec->catfile('.','Mediabot','ChannelCommands.pm'));

    # get_channel_by_name: 1p/1f after B26cc fix
    my $gcbn = _sub($src, 'get_channel_by_name');
    $assert->ok(defined $gcbn, 'get_channel_by_name sub found');
    my @p1 = ($gcbn =~ /->prepare\(/g);
    my @f1 = ($gcbn =~ /->finish/g);
    $assert->is(scalar(@f1), scalar(@p1),
        'get_channel_by_name: finish count equals prepare count (B26cc)');
    $assert->like($gcbn // '', qr/B26cc/, 'get_channel_by_name has B26cc fix comment');

    # channelList_ctx: 1p/1f
    my $cl = _sub($src, 'channelList_ctx');
    $assert->ok(defined $cl, 'channelList_ctx sub found');
    my @p2 = ($cl =~ /->prepare\(/g);
    my @f2 = ($cl =~ /->finish/g);
    $assert->is(scalar(@f2), scalar(@p2),
        'channelList_ctx: finish count equals prepare count (B26cc)');

    # registerChannel: 1p/1f
    my $rc = _sub($src, 'registerChannel');
    $assert->ok(defined $rc, 'registerChannel sub found');
    my @p3 = ($rc =~ /->prepare\(/g);
    my @f3 = ($rc =~ /->finish/g);
    $assert->is(scalar(@f3), scalar(@p3),
        'registerChannel: finish count equals prepare count (B26cc)');

    # channelUnban_ctx: 2p/1f is intentional (if/else exclusive prepares)
    my $cu = _sub($src, 'channelUnban_ctx');
    $assert->ok(defined $cu, 'channelUnban_ctx sub found');
    $assert->like($cu // '', qr/finish if \$sth/,
        'channelUnban_ctx uses conditional finish (safe pattern)');
};
