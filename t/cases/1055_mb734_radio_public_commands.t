use strict;
use warnings;
return sub {
    my ($assert)=@_;
    open my $run,'-|',$^X,'-I.','contrib/test_radio_public.pl' or die $!;
    local $/; my $output=<$run>//'';
    close $run;
    my $rc=$? >> 8;
    $assert->is($rc,0,'mb734: guest routing, private feedback, HTTPS and stale response guards');
    print $output if $rc;
    open my $sql,'<','install/mediabot.sql' or die $!;
    my $schema=<$sql>; close $sql;
    $assert->is(scalar(()=$schema=~/\(\d+, 'Radio'\)/g),1,'mb734: fresh install registers Radio once');
    open my $migration,'<','install/migrations/20260911_radio_chanset.sql' or die $!;
    my $m=<$migration>; close $migration;
    $assert->like($m,qr/WHERE NOT EXISTS/,'mb734: Radio migration is idempotent');
    $assert->ok($m!~/\b(?:ALTER|DROP|UPDATE|DELETE|CHANNEL_SET)\b/i,'mb734: migration neither changes schema nor enables channels');
};
