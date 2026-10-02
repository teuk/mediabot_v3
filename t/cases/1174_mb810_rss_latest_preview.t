use strict;
use warnings;
use utf8;
use File::Temp qw(tempdir);
use Encode qw(encode);
use Mediabot::Mediabot;
use Mediabot::Context;
use Mediabot::RSS qw(latest_feed_item);
use Mediabot::RSS::Commands;
use Mediabot::RSS::Pacing;
use Mediabot::CommandAsync;
use MockBot;
use MockUser;
{
    package MB810::Repo;
    sub new {bless {reads=>[],missing=>0,disabled=>0},shift}
    sub get_feed {
        my ($self,$channel,$label)=@_;
        push @{$self->{reads}},[$channel,$label];
        return undef if $self->{missing};
        return {label=>$label,channel=>$channel,url=>'https://example.org/rss',announce_limit=>10,enabled=>!$self->{disabled}};
    }
    sub AUTOLOAD {die 'Preview attempted a repository write or poll operation'}
    sub DESTROY {}
}
sub mb810_item {
    my ($title,$date)=@_;
    return {title=>$title,published=>$date,url=>'https://example.org/'.$title};
}
sub mb810_bytes {
    my ($path)=@_;open my $fh,'<:raw',$path or die $!;local $/;return <$fh>;
}
return sub {
    my ($a)=@_;
    my $older=mb810_item('Old','Fri, 02 Oct 2026 17:00:00 +0200');
    my $newer=mb810_item('New','2026-10-02T16:00:00Z');
    my $later=mb810_item('Latest','2026-10-02T19:00:00+02:00');
    $a->is(latest_feed_item([$older,$newer,$later])->{title},'Latest','mb810: newest dated article wins even when feed order is reversed');
    $a->is(latest_feed_item([$newer,$older])->{title},'New','mb810: RFC RSS and ISO Atom offsets compare in UTC');
    $a->is(latest_feed_item([$newer,mb810_item('Tie','Fri, 02 Oct 2026 16:00:00 GMT')])->{title},'New','mb810: equal dates preserve feed order');
    $a->is(latest_feed_item([mb810_item('First',undef),mb810_item('Second','invalid')])->{title},'First','mb810: no usable dates fall back to first readable entry');
    $a->is(latest_feed_item([mb810_item('Unzoned','2026-10-02T20:00:00'),$newer])->{title},'New','mb810: local timezone is never guessed');
    $a->is(latest_feed_item([{title=>'Missing URL',published=>'2026-10-02T22:00:00Z'},$older,$newer])->{title},'New','mb810: entries without article links do not hide valid latest article');
    for my $items (undef,{},[],[{title=>'   ',url=>'https://example.org/blank'}],[{title=>'Bad',url=>'javascript:bad'}],[{title=>{},url=>'https://example.org/x'}]) {
        $a->ok(!defined latest_feed_item($items),'mb810: unreadable or malformed input has no article');
    }
    my $dir=tempdir(CLEANUP=>1);
    my $pacing=Mediabot::RSS::Pacing->new(path=>"$dir/pacing.json",now=>sub{1000000});
    $pacing->configure('#35+ans',gap=>180,daily=>3);
    $pacing->reserve('#35+ans');
    my $state_before=mb810_bytes($pacing->{path});
    my $repo=MB810::Repo->new;
    my $user=MockUser->new(auth=>1,level=>'User');
    my $bot=MockBot->new(mock_user=>$user);
    my $ctx=Mediabot::Context->new(bot=>$bot,nick=>'Teuk',channel=>'#console',command=>'rss',args=>[]);
    my (@fetches,@jobs,@shortened,@cooldowns,@notices);
    my $wait=0;
    my $result={ok=>1,status=>200,feed=>{items=>[$older,$newer,$later]}};
    no warnings 'redefine';
    local *Mediabot::RSS::Commands::_repo=sub{$repo};
    local *Mediabot::RSS::Commands::_pacing=sub{$pacing};
    local *Mediabot::RSS::Commands::_url_shortener=sub{return sub{push @shortened,$_[0];$_[0]}};
    local *Mediabot::RSS::Commands::checkCmdCooldown=sub{push @cooldowns,[@_[1..3]];return $wait};
    local *Mediabot::RSS::Commands::botNotice=sub{push @notices,$_[2];1};
    local *Mediabot::RSS::Fetcher::fetch_feed_once=sub{my ($url,%opts)=@_;push @fetches,[$url,\%opts];return $result};
    local *Mediabot::CommandAsync::run_ctx_async=sub{push @jobs,$_[2];$_[3]->()};
    my %handlers=Mediabot::_builtin_public_command_handlers();
    my $run=sub{$ctx->{args}=[@_];$bot->reset_replies;return $handlers{rss}->($ctx)};
    $run->('#35+ans','latest','LeMonde');
    $a->is($repo->{reads}[-1][0],'#35+ans','mb810: console form selects destination subscription');
    $a->is($repo->{reads}[-1][1],'LeMonde','mb810: feed label reaches lookup');
    $a->is($jobs[-1],'rss latest','mb810: latest HTTP read is dispatched asynchronously');
    $a->is($fetches[-1][1]{max_items},100,'mb810: bounded date horizon is independent of max=10');
    $a->is(scalar keys %{$fetches[-1][1]},1,'mb810: preview passes no polling validators');
    $a->is(scalar @{$bot->{replies}},1,'mb810: one article emits exactly one response');
    $a->is($bot->{replies}[0]{to},'#console','mb810: selected destination never receives console preview');
    $a->is($bot->{replies}[0]{type},'privmsg','mb810: unprotected console receives public preview');
    $a->like($bot->{replies}[0]{text},qr/Latest.*https:\/\/example.org\/Latest/,'mb810: title and matching article link are shown');
    $a->is($shortened[-1],'https://example.org/Latest','mb810: shared shortener gets actual selected article URL');
    $a->is(join('|',@{$cooldowns[-1]}),'#console|rsslatest|15','mb810: cooldown protects the issuing channel across feed targets');
    $a->is(mb810_bytes($pacing->{path}),$state_before,'mb810: preview preserves all automatic quota/history bytes');
    $run->('latest','#35+ans','Le','Monde');
    $a->is(join('|',@{$repo->{reads}[-1]}),'#35+ans|Le Monde','mb810: legacy target position and multiword labels work');
    $ctx->{channel}='#35+ans';
    $run->('latest','LeMonde');
    $a->is($repo->{reads}[-1][0],'#35+ans','mb810: omitted destination uses current channel');
    $a->is($bot->{replies}[0]{type},'notice','mb810: protected issuing channel stays private');
    $a->is($bot->{replies}[0]{to},'Teuk','mb810: protected preview goes only to requester');
    $ctx->{channel}=undef;
    $run->('latest','#35+ans','LeMonde');
    $a->is($bot->{replies}[0]{type},'notice','mb810: private command replies privately');
    $ctx->{channel}='#console';
    $repo->{disabled}=1;
    $run->('#35+ans','latest','LeMonde');
    $a->is($bot->{replies}[0]{type},'privmsg','mb810: disabled subscription can be tested without enabling it');
    $a->ok($repo->{disabled},'mb810: preview cannot enable a subscription');
    my $fetch_count=@fetches;
    $repo->{missing}=1;
    $run->('#35+ans','latest','Missing');
    $a->is(scalar @fetches,$fetch_count,'mb810: unknown feed triggers no HTTP request');
    $a->like($bot->{replies}[0]{text},qr/not found/,'mb810: unknown feed error is explicit and private');
    $repo->{missing}=0;$result={ok=>0,error=>'http_status',status=>503};
    $run->('#35+ans','latest','LeMonde');
    $a->is($bot->{replies}[0]{type},'notice','mb810: HTTP failure never produces public article');
    $a->like($bot->{replies}[0]{text},qr/fetch failed: http_status/,'mb810: HTTP failure is explicit');
    $result={ok=>1,feed=>{items=>[]}};
    $run->('#35+ans','latest','LeMonde');
    $a->like($bot->{replies}[0]{text},qr/no readable article/,'mb810: empty feed handled privately');
    $result={ok=>1,feed=>{items=>[{title=>'Été 🦆 ' x 100,url=>'https://example.org/long',published=>''}]}};
    $run->('#35+ans','latest','LeMonde');
    $a->ok(length(encode('UTF-8',$bot->{replies}[0]{text}))<=400,'mb810: emoji preview fits one wire line');
    $a->like($bot->{replies}[0]{text},qr/https:\/\/example.org\/long\001\z/,'mb810: URL and closing ACTION stay intact');
    $result={ok=>1,feed=>{items=>[{title=>'Long URL',url=>'https://example.org/'.('a'x500)}]}};
    $run->('#35+ans','latest','LeMonde');
    $a->like($bot->{replies}[0]{text},qr/cannot fit/,'mb810: unshortened oversized URL cannot create multiple lines');
    $wait=7;$fetch_count=@fetches;
    $run->('#35+ans','latest','LeMonde');
    $a->is(scalar @fetches,$fetch_count,'mb810: cooldown blocks network fetch');
    $a->like($notices[-1],qr/latest cooldown: 7s/,'mb810: cooldown reported privately');
    $wait=0;$user->{auth}=0;
    $run->('#35+ans','latest','LeMonde');
    $a->is(scalar @fetches,$fetch_count,'mb810: anonymous caller cannot fetch feed');
    $user->{auth}=1;
    my $reads=@{$repo->{reads}};
    $run->('#35+ans','latest');
    $run->('#35+ans','latest','#console','LeMonde');
    $a->is(scalar @{$repo->{reads}},$reads,'mb810: missing label / duplicate target reject before repository access');
    # Exercise the actual asynchronous intent collector with a real bot class.
    my $real=bless {%$bot},'Mediabot';
    my $real_ctx=Mediabot::Context->new(bot=>$real,nick=>'Teuk',channel=>'#console',command=>'rss',args=>[]);
    $result={ok=>1,feed=>{items=>[$newer]}};
    my ($intents,$truncated,$ok,$err)=Mediabot::CommandAsync::_collect_intents_run(sub {
        Mediabot::RSS::Commands::_latest_worker($real_ctx,'#35+ans','LeMonde');
    });
    $a->ok($ok && !$truncated && !defined($err),'mb810: actual async collector completes without socket writes');
    $a->is(scalar @$intents,1,'mb810: async collector returns one replayable intent');
    $a->is(join('|',@{$intents->[0]}[0,1]),'privmsg|#console','mb810: replay target is issuing console');
    $a->is(mb810_bytes($pacing->{path}),$state_before,'mb810: complete command matrix leaves quota history untouched');
};
