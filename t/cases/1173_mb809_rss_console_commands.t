use strict;
use warnings;
use File::Temp qw(tempdir);
use Mediabot::Mediabot;
use Mediabot::RSS::Commands;
use Mediabot::RSS::Pacing;
use Mediabot::Context;
use MockBot;
use MockUser;
{
    package MB809::Channel;
    sub get_id {$_[0]{id}}
}
{
    package MB809::CommandRepo;
    sub add_feed {my ($s,%args)=@_;push @{$s->{add}},\%args;1}
    sub list_feeds {push @{$_[0]{list}},$_[1];[]}
    sub get_feed {push @{$_[0]{get}},[$_[1],$_[2]];return {label=>$_[2],channel=>$_[1],url=>'https://example.org/rss',enabled=>1,poll_interval=>1800,announce_limit=>1}}
    sub update_feed_setting {push @{$_[0]{set}},[@_[1..$#_]];1}
    sub delete_feed {push @{$_[0]{del}},[$_[1],$_[2]];1}
}
return sub {
    my ($a)=@_;
    my $dir=tempdir(CLEANUP=>1);
    my $p=Mediabot::RSS::Pacing->new(path=>"$dir/pacing.json",now=>sub{1000000});
    my $repo=bless {},'MB809::CommandRepo';
    my $user=MockUser->new(auth=>1,level=>'User');
    my $bot=MockBot->new(mock_user=>$user);
    $bot->{channels}{'#35+ans'}=bless {id=>35},'MB809::Channel';
    $bot->{channels}{'#console'}=bless {id=>1},'MB809::Channel';
    my (@acl,@notices);my $permission=1;
    no warnings 'redefine';
    local *Mediabot::RSS::Commands::_repo=sub{$repo};
    local *Mediabot::RSS::Commands::_pacing=sub{$p};
    local *Mediabot::RSS::Commands::checkUserChannelLevel=sub {push @acl,[$_[2],$_[4]];return $permission};
    local *Mediabot::RSS::Commands::logBot=sub{1};
    local *Mediabot::RSS::Commands::botNotice=sub{push @notices,$_[2];1};
    local *Mediabot::CommandAsync::run_ctx_async=sub{$_[3]->()};
    local *Mediabot::RSS::Fetcher::fetch_feed_once=sub{return {ok=>1,status=>200,feed=>{title=>'LeMonde',format=>'RSS',items=>[{title=>'Article',url=>'https://example.org/article'}]}}};
    my %handlers=Mediabot::_builtin_public_command_handlers();
    my $ctx=Mediabot::Context->new(bot=>$bot,nick=>'Teuk',channel=>'#console',command=>'rss',args=>[]);
    my $run=sub{$ctx->{args}=[@_];$handlers{rss}->($ctx)};
    $run->('#35+ans','limit','gap=180','daily=3');
    $a->is($acl[-1][0],'#35+ans','mb809: console limit checks rights on destination channel');
    $a->is($acl[-1][1],400,'mb809: destination level is 400');
    $a->is($p->status('#35+ans')->{gap},180,'mb809: new console form stores channel gap');
    $a->is($p->status('#35+ans')->{daily},3,'mb809: new console form stores rolling quota');
    $a->is($bot->{replies}[-1]{type},'notice','mb809: limit confirmation is private');
    $a->is($bot->{replies}[-1]{to},'Teuk','mb809: no control response advertised on destination');
    $run->('#35+ans','add','Le','Monde','https://example.org/rss','interval=30','max=1');
    $a->is($repo->{add}[-1]{id_channel},35,'mb809: new add targets requested registered channel');
    $a->is($repo->{add}[-1]{label},'Le Monde','mb809: multiword feed label still supported');
    $a->is($repo->{add}[-1]{poll_interval},1800,'mb809: polling remains independent of delivery gap');
    $a->is($repo->{add}[-1]{announce_limit},1,'mb809: feed max is parsed normally');
    $a->is($bot->{replies}[-1]{to},'#console','mb809: add acknowledgement stays in issuing console');
    $run->('add','#35+ans','Legacy','https://example.org/legacy');
    $a->is($repo->{add}[-1]{id_channel},35,'mb809: legacy subcommand-first form preserved');
    $a->is($repo->{add}[-1]{announce_limit},5,'mb809: existing add defaults preserved');
    $run->('#35+ans','list');
    $a->is($repo->{list}[-1],'#35+ans','mb809: console list queries destination');
    $run->('#35+ans','info','Le','Monde');
    $a->is($repo->{get}[-1][0],'#35+ans','mb809: console info targets destination');
    $a->like(join(' ',@notices),qr/gap=180.*daily=3/,'mb809: info includes channel delivery limits');
    $run->('#35+ans','set','Le','Monde','enabled','off');
    $a->is(join('|',@{$repo->{set}[-1]}),'#35+ans|Le Monde|enabled|off','mb809: console set keeps target and full label');
    $run->('#35+ans','del','Le','Monde');
    $a->is(join('|',@{$repo->{del}[-1]}),'#35+ans|Le Monde','mb809: console delete normalized');
    $permission=0;
    $run->('#35+ans','limit','gap=60','daily=5');
    $a->is($p->status('#35+ans')->{gap},180,'mb809: console rights cannot bypass destination denial');
    my $adds=@{$repo->{add}};
    $run->('#35+ans','add','Denied','https://example.org/denied');
    $a->is(scalar @{$repo->{add}},$adds,'mb809: unauthorized add never touches DB');
    $permission=1;
    for my $args (['gap=1'],['daily=25'],['gap=180','gap=60'],['whatever=4']) {
        $run->('#35+ans','limit',@$args);
    }
    $a->is($p->status('#35+ans')->{gap},180,'mb809: malformed or duplicate limits preserve current policy');
    $run->('#35+ans','add','#console','Hidden','https://example.org/hidden');
    $a->is(scalar @{$repo->{add}},$adds,'mb809: two destination channels are rejected');
    $ctx->{channel}='#35+ans';$bot->reset_replies;
    $run->('show','Le','Monde');
    $a->is($bot->{replies}[-1]{type},'notice','mb809: manual show on protected salon is private');
    $run->('probe','https://example.org/rss');
    $a->is($bot->{replies}[-1]{type},'notice','mb809: manual probe cannot flood protected salon');
    $a->ok(!grep({$_->{type} eq 'privmsg'} @{$bot->{replies}}),'mb809: manual protected previews produce no public news');
    $user->{auth}=0;my $gap=$p->status('#35+ans')->{gap};
    $run->('limit','gap=60');
    $a->is($p->status('#35+ans')->{gap},$gap,'mb809: unauthenticated user cannot change limits');
};
