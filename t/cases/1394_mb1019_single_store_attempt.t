use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use JSON::PP ();
use Mediabot::PluginManager;
use Mediabot::ScriptActionRunner;

{
    package MB1019::Conf;
    sub get { $_[1] eq 'plugins.DATA_DIR' ? $_[0]{dir} : undef }
    package MB1019::Log;
    sub log { push @{$_[0]{lines}}, [@_[1,2]]; 1 }
    package MB1019::Metrics;
    sub inc { $_[0]{$_[1]}++; 1 }
    sub set { $_[0]{$_[1]} = $_[2]; 1 }
    package MB1019::IRC;
    sub send_message { push @{$_[0]{sent}}, [@_[1..$#_]]; 1 }
}
my @warnings;
local $SIG{__WARN__} = sub { push @warnings, @_ };
sub setup_1394 {
    my $dir = tempdir(CLEANUP=>1);
    my $bot = {conf=>bless({dir=>$dir},'MB1019::Conf'),
        logger=>bless({lines=>[]},'MB1019::Log'),
        metrics=>bless({},'MB1019::Metrics'),
        irc=>bless({sent=>[]},'MB1019::IRC')};
    return ($dir,$bot,Mediabot::PluginManager->new(bot=>$bot),
        Mediabot::ScriptActionRunner->new(bot=>$bot));
}
sub result_1394 {
    # Go through ordinary JSON types, not a hand-built prevalidated action plan.
    return JSON::PP::decode_json(JSON::PP::encode_json({ok=>1,
        response=>{ok=>1,actions=>[@_]}}));
}
sub stores_1394 {
    return result_1394(map {{type=>'store',data=>{n=>$_}}} @_);
}
sub errors_1394 { [map {[@$_{qw(index type error)}]} @{$_[0]{apply_errors}}] }
my $duplicate = 'only one store action per run';
{
    my ($dir,$bot,$pm,$ar) = setup_1394();
    my @calls;
    my $ctx = {channel=>'#test'};
    my $plan = $ar->apply_actions(stores_1394(1,2),$ctx,
        apply=>1,allow_store=>1,store_sink=>sub {
            push @calls, [$_[0]{n}, $_[1] == $ctx ? 1 : 0];
            return $pm->_store_plugin_data('probe',$_[0]);
        });
    is_deeply([\@calls,$pm->_read_plugin_data('probe'),$plan->{applied},
        errors_1394($plan),$plan->{applied_ok},$bot->{metrics}{mediabot_plugin_store_total}],
        [[[1,1]],{n=>1},[{index=>0,type=>'store'}],[[1,'store',$duplicate]],0,1],
        'a successful first store still wins, keeps its context and native metrics, and rejects the duplicate');
}
{
    my (undef,undef,undef,$ar) = setup_1394();
    my @calls;
    my $state = 0;
    my $plan = $ar->apply_actions(stores_1394(1,2),{},
        apply=>1,allow_store=>1,store_sink=>sub {
            push @calls,$_[0]{n};
            return (0,'fixture refused') if @calls == 1;
            $state = $_[0]{n}; return (1,undef);
        });
    is_deeply([\@calls,$state,$plan->{applied},errors_1394($plan),$plan->{applied_ok}],
        [[1],0,[],[[0,'store','fixture refused'],[1,'store',$duplicate]],0],
        'a false first receipt cannot promote the later document into a second storage attempt');
}
{
    my (undef,undef,undef,$ar) = setup_1394();
    my @calls;
    my $plan = $ar->apply_actions(stores_1394(1,2),{},
        apply=>1,allow_store=>1,store_sink=>sub {
            push @calls,$_[0]{n};
            die "fixture store exception\n" if @calls == 1;
            return (1,undef);
        });
    is_deeply([\@calls,$plan->{applied},errors_1394($plan),$plan->{applied_ok}],
        [[1],[],[[0,'store',"fixture store exception\n"],[1,'store',$duplicate]],0],
        'an exception consumes the same single attempt while retaining the original failure diagnostic');
}
{
    my ($dir,$bot,$pm,$ar) = setup_1394();
    my @calls;
    my $plan = $ar->apply_actions(stores_1394(1,2),{},
        apply=>1,allow_store=>1,store_sink=>sub {
            push @calls,$_[0]{n};
            my @stored = $pm->_store_plugin_data('probe',$_[0]);
            # Model an uncertain acknowledgement AFTER actual atomic publication.
            return (0,'fixture receipt unavailable') if @calls == 1;
            return @stored;
        });
    is_deeply([\@calls,$pm->_read_plugin_data('probe'),$plan->{applied},errors_1394($plan),
        $plan->{applied_ok},$bot->{metrics}{mediabot_plugin_store_total},
        [glob("$dir/probe.json.tmp.*")]],
        [[1],{n=>1},[],[[0,'store','fixture receipt unavailable'],[1,'store',$duplicate]],0,1,[]],
        'a real published document survives a lost acknowledgement without a later document replacing it');
}
{
    my ($dir,$bot,$pm,$ar) = setup_1394();
    my ($seeded) = $pm->_store_plugin_data('probe',{n=>0});
    die 'seed failed' unless $seeded;
    # Deterministic native open failure, including when the tests run as root.
    my $blocked = "$dir/probe.json.tmp.$$";
    mkdir $blocked or die "fixture directory: $!";
    my @calls;
    my $plan = $ar->apply_actions(stores_1394(1,2),{},
        apply=>1,allow_store=>1,store_sink=>sub {
            push @calls,$_[0]{n};
            my @stored = $pm->_store_plugin_data('probe',$_[0]);
            rmdir $blocked or die "remove fixture directory: $!" if @calls == 1;
            return @stored;
        });
    is_deeply([\@calls,$pm->_read_plugin_data('probe'),$plan->{applied},$plan->{applied_ok},
        $plan->{apply_errors}[0]{error} =~ /\Acannot write / ? 1 : 0,
        $plan->{apply_errors}[1]{error},$bot->{metrics}{mediabot_plugin_store_total},
        -e $blocked ? 1 : 0],
        [[1],{n=>0},[],0,1,$duplicate,1,0],
        'an actual native disk-open failure preserves previous bytes even if the filesystem recovers before the next action');
}
{
    my (undef,undef,$pm,$ar) = setup_1394();
    my @calls;
    my $sink = sub {
        push @calls,$_[0]{n};
        return (0,'fixture refused') if @calls == 1;
        return $pm->_store_plugin_data('probe',$_[0]);
    };
    my $first = $ar->apply_actions(stores_1394(1),{},apply=>1,allow_store=>1,store_sink=>$sink);
    my $next = $ar->apply_actions(stores_1394(3),{},apply=>1,allow_store=>1,store_sink=>$sink);
    is_deeply([\@calls,$first->{applied_ok},$next->{applied_ok},$pm->_read_plugin_data('probe')],
        [[1,3],0,1,{n=>3}],
        'a new invocation gets a fresh attempt after the previous invocation failed');
}
{
    my (undef,undef,undef,$ar) = setup_1394();
    my $calls = 0;
    my $sink = sub {$calls++; (1,undef)};
    my $dry = $ar->apply_actions(stores_1394(1,2),{},allow_store=>1,store_sink=>$sink);
    my $gate = $ar->apply_actions(stores_1394(1,2),{},apply=>1,store_sink=>$sink);
    my $missing = $ar->apply_actions(stores_1394(1,2),{},apply=>1,allow_store=>1);
    my $invalid = $ar->apply_actions(result_1394({type=>'store',data=>'invalid'}),{},
        apply=>1,allow_store=>1,store_sink=>$sink);
    is_deeply([$calls,$dry->{dry_run},scalar @{$dry->{planned}},
        [map {$_->{error}} @{$gate->{apply_errors}}],
        [map {$_->{error}} @{$missing->{apply_errors}}],$invalid->{ok}],
        [0,1,2,[('store actions require allow_store and a store sink') x 2],
         [('store actions require allow_store and a store sink') x 2],0],
        'dry runs, closed gates, missing sinks and invalid plans still perform no storage calls');
}
{
    my (undef,$bot,undef,$ar) = setup_1394();
    my @calls;
    my $plan = $ar->apply_actions(result_1394(
        {type=>'store',data=>{n=>1}}, {type=>'log',level=>'info',text=>'fixture log'},
        {type=>'reply',text=>'fixture reply'}, {type=>'store',data=>{n=>2}}),
        {channel=>'#test'},apply=>1,allow_store=>1,allow_irc=>1,store_sink=>sub {
            push @calls,$_[0]{n};
            return @calls == 1 ? (0,'fixture refused') : (1,undef);
        });
    is_deeply([\@calls,$plan->{applied},errors_1394($plan),$plan->{applied_ok},
        $bot->{logger}{lines},$bot->{irc}{sent},\@warnings],
        [[1],[{index=>1,type=>'log'},{index=>2,type=>'reply',target=>'#test'}],
         [[0,'store','fixture refused'],[3,'store',$duplicate]],0,
         [['info','fixture log']],[['PRIVMSG',undef,'#test','fixture reply']],[]],
        'a rejected duplicate does not stop unrelated authorized actions or hide the first storage error');
}
done_testing;
