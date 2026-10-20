use strict;
use warnings;
use utf8;
use lib '.', 't/lib';
use Test::More;
use MockBot;
use Mediabot::Context;
use Mediabot::DBCommands;

my @logged;
no warnings qw(redefine once);
local *Mediabot::DBCommands::logBot=sub {push @logged, [@_]};
use warnings;
for my $case (
    [['12','in','cm'],qr/12 in = 30\.48 cm/],
    [['12','in','to','cm'],qr/12 in = 30\.48 cm/],
    [['1','m','in'],qr/1 m = 39\.370079 in/],
    [['1','m','to','in'],qr/1 m = 39\.370079 in/],
    [['1','m','in','in'],qr/1 m = 39\.370079 in/],
    [['1','in','in','m'],qr/1 in = 0\.0254 m/],
    [['12','in','in'],qr/12 in = 12 in/],
    [['12','IN','TO','CM'],qr/12 in = 30\.48 cm/],
    [['1','inch','to','cm'],qr/1 in = 2\.54 cm/],
    [['100','km','in','mi'],qr/100 km = 62\.137119 mi/],
    [['1e300','tb','to','tb'],qr/1e\+300 TB = 1e\+300 TB/],
) {
    my ($args,$expected)=@$case;
    for my $channel ('#test',undef) {
        my $bot=MockBot->new;@logged=();
        my $ctx=Mediabot::Context->new(bot=>$bot,nick=>'alice',channel=>$channel,
            command=>'convert',message=>'local conversion fixture',args=>[@$args]);
        ok(eval {Mediabot::DBCommands::mbConvert_ctx($ctx);1},'conversion handler completes without exception');
        my @replies=$bot->replies;
        is(scalar @replies,1,'valid conversion produces exactly one reply');
        is($replies[0]{type},defined($channel)?'privmsg':'notice','success uses the existing context delivery route');
        is($replies[0]{to},$channel//'alice','success reaches only the intended channel or caller');
        like($replies[0]{text},$expected,'inch units and optional separators retain their positional meaning');
        is(scalar @logged,1,'one successful conversion is logged once');
    }
}
for my $args (['1e9999','m','km'],['1e308','tb','b'],['1e308','c','f'],['abc','in','cm'],
              ['1','in'],['1','km','kg'],['1','unknown','cm'],[('1'x65),'m','cm']) {
    my $bot=MockBot->new;@logged=();
    my $ctx=Mediabot::Context->new(bot=>$bot,nick=>'alice',channel=>'#test',
        command=>'convert',message=>'local invalid fixture',args=>[@$args]);
    ok(eval {Mediabot::DBCommands::mbConvert_ctx($ctx);1},'invalid conversion remains a normal command result');
    my @replies=$bot->replies;
    is(scalar @replies,1,'invalid conversion produces one useful response');
    is($replies[0]{type},'notice','invalid conversion remains private');
    is($replies[0]{to},'alice','invalid conversion reaches only its caller');
    unlike($replies[0]{text},qr/=.*\b(?:Inf|NaN)\b/i,'invalid conversion cannot publish a non-finite success');
    is(scalar @logged,0,'refused conversion creates no successful-conversion audit event');
}
done_testing;
