use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use Mediabot::RandomQuote::State;

my $dir=tempdir(CLEANUP=>1);
my $path="$dir/state.json";
my ($now,$step,$reads)=(1000000,0,0);
my $state=Mediabot::RandomQuote::State->new(path=>$path,now=>sub {
    ++$reads; my $value=$now; $now+=$step; return $value;
});
$state->configure('#test',900,10800);
my $deadline=$state->status('#test',10800)->{next_at};
open my $fh,'<:raw',$path or die $!;
my $original=do {local $/;<$fh>};close $fh;
for my $method (qw(status observe)) {
    for my $offset (-100,-1,0,1,100) {
        ($now,$step,$reads)=($deadline+$offset,2,0);
        my $result=$state->$method('#test',10800);
        is($result->{wait},$offset<0 ? -$offset : 0,"$method wait uses one observation of time");
        is($reads,1,"$method reads the clock once for an existing schedule");
        cmp_ok($result->{wait},'>=',0,"$method never returns a negative wait");
        is($result->{next_at},$deadline,"$method preserves the scheduled deadline");
    }
    ($now,$step,$reads)=($deadline-1,2,0);
    my $result=$state->$method('#unknown',10800);
    is($reads,0,"$method needs no clock for an unscheduled channel");
    is($result->{interval},10800,"$method preserves default interval");
}
open $fh,'<:raw',$path or die $!;
my $after=do {local $/;<$fh>};close $fh;
is($after,$original,'status and observation do not rewrite persistent state');
done_testing;
