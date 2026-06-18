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

    my $gcbn = _sub($src, 'get_channel_by_name');
    $assert->ok(defined $gcbn, 'get_channel_by_name sub found');
    $assert->like($gcbn // '', qr/unless \(\$sth\).*?return undef;/s,
        'get_channel_by_name handles prepare failure');
    $assert->like($gcbn // '', qr/unless \(\$sth && \$sth->execute\(\$name\)\).*?\$sth->finish if \$sth;.*?return undef;/s,
        'get_channel_by_name finishes statement on execute failure');
    $assert->like($gcbn // '', qr/fetchrow_hashref;.*?\$sth->finish;/s,
        'get_channel_by_name finishes statement on success');

    my $cl = _sub($src, 'channelList_ctx');
    $assert->ok(defined $cl, 'channelList_ctx sub found');
    $assert->like($cl // '', qr/unless \(\$sth\).*?SQL prepare error/s,
        'channelList_ctx handles prepare failure');
    $assert->like($cl // '', qr/unless \(\$sth && \$sth->execute\(\)\).*?\$sth->finish if \$sth;/s,
        'channelList_ctx finishes statement on execute failure');
    $assert->like($cl // '', qr/while \(my \$ref = \$sth->fetchrow_hashref\(\)\).*?\$sth->finish;/s,
        'channelList_ctx finishes statement after reading rows');

    my $rc = _sub($src, 'registerChannel');
    $assert->ok(defined $rc, 'registerChannel sub found');
    $assert->like($rc // '', qr/unless \(\$sth && \$sth->execute\(\$id_user,\$id_channel\)\).*?\$sth->finish if \$sth;/s,
        'registerChannel finishes statement on execute failure');
    $assert->like($rc // '', qr/else \{.*?\$sth->finish;.*?return 1;/s,
        'registerChannel finishes statement on success');

    my $cu = _sub($src, 'channelUnban_ctx');
    $assert->ok(defined $cu, 'channelUnban_ctx sub found');
    $assert->like($cu // '', qr/finish if \$sth/,
        'channelUnban_ctx uses conditional finish (safe pattern)');
};
