use strict;
use warnings;
use utf8;
use Test::More;
use Mediabot::Spark::DryRun;
my $summary={action=>'ready',reason=>'generated',kind=>'fork',generation=>1};
for my $bad ('#', '#two words', "#test\nforged", "#test\rforged", "#test\tforged",
             "#test\0forged", "#test\x7f", '#a,b', '#a:b', '#'.('a'x80), undef, [], 'test') {
    ok(!defined Mediabot::Spark::DryRun::format_ai_dryrun_log($bad,$summary), 'invalid channel rejected before log construction');
}
for my $valid ('#test','#A[B]','##room','#café','#'.('a'x79)) {
    my $line=Mediabot::Spark::DryRun::format_ai_dryrun_log($valid,$summary);
    is($line,"[SPARK_AI_DRYRUN] channel=$valid action=ready reason=generated kind=fork generation=1",'valid channel retains exact log format');
    unlike($line,qr/[\r\n\x00-\x1f\x7f]/,'log stays on one safe line');
}
done_testing;
