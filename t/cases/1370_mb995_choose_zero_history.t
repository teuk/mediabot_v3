use strict;
use warnings;
use utf8;
use Test::More;
use Storable qw(dclone);
our (@DRAWS, @LIMITS, $DRAWING);
BEGIN {
    *CORE::GLOBAL::rand = sub {
        return CORE::rand($_[0] // 1) unless $DRAWING;
        die "unexpected random draw\n" unless @DRAWS;
        push @LIMITS, $_[0];
        return shift(@DRAWS) * ($_[0] // 1);
    };
}
use Mediabot::Mediabot;
use Mediabot::Context;
binmode Test::More->builder->output, ':encoding(UTF-8)';
binmode Test::More->builder->failure_output, ':encoding(UTF-8)';
my (@wire, @audit, @warnings);
local $SIG{__WARN__} = sub { push @warnings, @_ };
no warnings qw(redefine once);
local *Mediabot::UserCommands::botPrivmsg = sub { push @wire, [$_[1],$_[2]]; 1 };
local *Mediabot::UserCommands::botNotice = sub { die "unexpected notice\n" };
local *Mediabot::UserCommands::logBot = sub { push @audit, [@_[2..$#_]]; 1 };
my $bot = Mediabot->new({});
sub invoke_1370 {
    my ($args, $channel, @draws) = @_;
    @wire = (); @DRAWS = @draws; @LIMITS = ();
    my $ctx = Mediabot::Context->new(bot=>$bot,nick=>'Alice',
        channel=>$channel,command=>'choose',args=>$args);
    { local $DRAWING = 1; $bot->command_registry->handler_for('choose','public')->($ctx) }
    return dclone([\@wire, \@LIMITS, \@DRAWS]);
}
sub state_1370 { dclone([$bot->{_choose_last}, $bot->{_choose_history}, \@audit]) }
is_deeply(invoke_1370(['last'], '#test'),
    [[['#test','Alice: no previous choice on this channel.']],[],[]],
    'a channel without a previous draw still reports no choice');
my $draw = invoke_1370(['0','|','1'], '#test', 0);
is_deeply([$draw, state_1370()],
    [[[['#test','Alice: I choose... 0!']],[2],[]],
     [{ '#test'=>'0' }, { '#test'=>['0'] }, [['#test','choose','0']]]],
    'real registered choose accepts zero, performs one bounded draw and records it once');
my $before_reads = state_1370();
is_deeply(invoke_1370(['last'], '#test'),
    [[['#test','Alice: last choice was: 0']],[],[]],
    'last recalls a genuine zero without drawing again');
is_deeply(invoke_1370(['history'], '#test'),
    [[['#test','Last choices: 0']],[],[]],
    'rolling history retains the same zero');
my $other = invoke_1370(['last'], '#other');
is_deeply([$other,state_1370()],
    [[[['#other','Alice: no previous choice on this channel.']],[],[]],$before_reads],
    'last/history reads preserve stored results and audit, without leaking across channels');
$draw = invoke_1370(['0:2','|','café'], '#test', 0);
is_deeply([$draw,state_1370()],
    [[[['#test','Alice: I choose... 0! (1 of 3 options)']],[3],[]],
     [{ '#test'=>'0' }, { '#test'=>['0','0'] },
      [['#test','choose','0'],['#test','choose','0']]]],
    'a weighted zero keeps its label, pool size, history and single audit entry');
is_deeply(invoke_1370(['last'], '#test'),
    [[['#test','Alice: last choice was: 0']],[],[]],
    'last also recalls zero obtained from a weighted option');
$draw = invoke_1370(['café','ou','eau'], '#test', 0);
my $last = invoke_1370(['last'], '#test');
is_deeply([$draw,$last,state_1370()],
    [[[['#test','Alice: I choose... café!']],[2],[]],
     [[['#test','Alice: last choice was: café']],[],[]],
     [{ '#test'=>'café' }, { '#test'=>['0','0','café'] },
      [['#test','choose','0'],['#test','choose','0'],['#test','choose','café']]]],
    'a later Unicode choice through the French separator replaces last and preserves prior zeros');
is_deeply(\@warnings, [], 'zero choice recall emits no warnings');
done_testing;
