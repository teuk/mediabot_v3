# t/cases/246_usercommands_remindlist.t
# Verify mbRemindList_ctx structure.
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
    my $body = _sub($src, 'mbRemindList_ctx');
    $assert->ok(defined $body, 'mbRemindList_ctx sub found');
    $assert->like($body // '', qr/REMINDERS/,
        'mbRemindList_ctx queries REMINDERS table');
    $assert->like($body // '', qr/delivered.*0|WHERE.*nick/i,
        'mbRemindList_ctx filters pending reminders');
    $assert->like($body // '', qr/->finish/,
        'mbRemindList_ctx calls ->finish');
    $assert->like($body // '', qr/no pending|No.*reminder/i,
        'mbRemindList_ctx handles empty result');
    my $mm = _slurp(File::Spec->catfile('.','Mediabot','Mediabot.pm'));
    $assert->like($mm, qr/remindlist\|/,
        'Mediabot.pm has help entry for !remindlist');
};
