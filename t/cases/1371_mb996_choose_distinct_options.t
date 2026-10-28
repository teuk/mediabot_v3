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
use Mediabot::PluginContext;
use Mediabot::Plugin::InvocationV3;
require './plugins/playful-v3/lib/Playful.pm';
binmode Test::More->builder->output, ':encoding(UTF-8)';
binmode Test::More->builder->failure_output, ':encoding(UTF-8)';
my (@wire, @audit, @warnings);
local $SIG{__WARN__} = sub { push @warnings, @_ };
no warnings qw(redefine once);
local *Mediabot::UserCommands::botPrivmsg = sub { push @wire, ['public',$_[1],$_[2]]; 1 };
local *Mediabot::UserCommands::botNotice = sub { push @wire, ['notice',$_[1],$_[2]]; 1 };
local *Mediabot::UserCommands::logBot = sub { push @audit, [@_[2..$#_]]; 1 };
my $authority = Mediabot::PluginContext->new(plugin=>'playful-v3',
    requested=>[qw(irc.reply irc.notice)],granted=>[qw(irc.reply irc.notice)]);
my ($bot, $plugin);
sub run_1371 {
    my ($kind,$args,$channel,$fraction) = @_;
    @wire = (); @LIMITS = (); @DRAWS = ($fraction);
    my ($input,$call);
    if ($kind eq 'native') {
        $input = Mediabot::Context->new(bot=>$bot,nick=>'Alice',channel=>$channel,
            command=>'choose',args=>[@$args]);
        $call = sub { $bot->command_registry->handler_for('choose','public')->($input) };
    } else {
        $input = Mediabot::Plugin::InvocationV3->new(nick=>'Alice',channel=>$channel,
            command=>'choose',args=>$args,source=>'public',is_private=>0,
            authority=>$authority,activation=>'on',config=>{},
            reply_sink=>sub { push @wire, ['public',$channel,$_[0]]; 1 },
            notice_sink=>sub { push @wire, ['notice','Alice',$_[0]]; 1 });
        $call = sub { $plugin->command_choose($authority,$input) };
    }
    { local $DRAWING = 1; $call->() }
    return dclone({wire=>\@wire,limits=>\@LIMITS,remaining=>\@DRAWS,args=>$input->args});
}
sub setup_1371 {
    $bot = Mediabot->new({});
    $plugin = Mediabot::Plugin::Playful->new(context=>$authority); @audit = ();
    for my $kind (qw(native plugin)) {
        run_1371($kind, ['café','|','tea'], '#test', 0);
        run_1371($kind, ['water','|','milk'], '#other', 0);
    }
}
sub state_1371 {
    dclone([$bot->{_choose_last}, $bot->{_choose_history},
            $plugin->{choose_last}, $plugin->{choose_history}, \@audit]);
}
my $single = 'Only one option left after deduplication — nothing to choose from.';
for my $case (
    [['solo'], [$single]],
    [['solo:3'], [$single]],
    [['solo:2','|','SOLO:3'], [$single]],
    [['café:2','ou','CAFÉ'], [$single]],
    [['0:2','|','0'], [$single]],
    [['0:3'], [$single]],
    [['solo','|','SOLO'], ['Note: 1 duplicate option(s) removed.', $single]],
    [[], ['No valid options remain after deduplication.']],
) {
    my ($args,$notices) = @$case;
    setup_1371(); my $before = state_1371();
    my $expected = {wire=>[map { ['notice','Alice',$_] } @$notices],
        limits=>[],remaining=>[0],args=>$args};
    my @actual = map { run_1371($_,$args,'#test',0) } qw(native plugin);
    is_deeply([\@actual,state_1371()], [[$expected,$expected],$before],
        'no distinct alternative: private refusal before draw, history or audit: ' . join(' ', @$args));
}
for my $case (
    [['0:2','|','café'], 0, '0', 3],
    [['0:2','|','café'], .999, 'café', 3],
    [['tea:2','|','TEA:3','|','café'], .4, 'TEA', 6],
) {
    my ($args,$fraction,$choice,$size) = @$case;
    setup_1371();
    my $expected = {wire=>[['public','#test',"Alice: I choose... $choice! (1 of $size options)"]],
        limits=>[$size],remaining=>[],args=>$args};
    my @actual = map { run_1371($_,$args,'#test',$fraction) } qw(native plugin);
    my $last = {'#test'=>$choice,'#other'=>'water'};
    my $history = {'#test'=>['café',$choice],'#other'=>['water']};
    is_deeply([\@actual,state_1371()], [[$expected,$expected],
        [$last,$history,$last,$history,
         [['#test','choose','café'],['#other','choose','water'],['#test','choose',$choice]]]],
        'valid alternatives retain weighted pool positions, labels, histories and channel scope');
}
is_deeply(\@warnings, [], 'distinct-option validation emits no warnings');
done_testing;
