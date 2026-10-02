use strict;
use warnings;
use utf8;
use File::Temp qw(tempdir);
use Encode qw(encode);
use Mediabot::Mediabot;
use Mediabot::Context;
use Mediabot::RSS qw(format_rss_announcement);
use Mediabot::RSS::Commands;
use Mediabot::RSS::Pacing;
use Mediabot::CommandAsync;
use MockBot;
use MockUser;
{
    package MB811::Repo;
    sub get_feed {return {label=>'20 Minutes',url=>'https://example.org/rss',announce_limit=>1}}
    sub AUTOLOAD {die 'Preview must not write polling state'}
    sub DESTROY {}
}
sub mb811_bytes {
    my ($path)=@_;open my $fh,'<:raw',$path or die $!;local $/;return <$fh>;
}
return sub {
    my ($a)=@_;
    my $dir=tempdir(CLEANUP=>1);
    my $pacing=Mediabot::RSS::Pacing->new(path=>"$dir/pacing.json",now=>sub{1000000});
    $pacing->configure('#35+ans',gap=>180,daily=>3);
    $pacing->reserve('#35+ans');
    my $before=mb811_bytes($pacing->{path});
    my $bot=MockBot->new(mock_user=>MockUser->new(auth=>1,level=>'User'));
    my $ctx=Mediabot::Context->new(bot=>$bot,nick=>'Teuk',channel=>'#35+ans',command=>'rss',args=>[]);
    my $repo=bless {},'MB811::Repo';
    my $url='https://teuk.org/shorturl/example';
    my $title="Un titre à lire normalement";
    my $result={ok=>1,status=>200,feed=>{title=>'20 Minutes',format=>'RSS',items=>[{title=>$title,url=>$url}]}};
    no warnings 'redefine';
    local *Mediabot::RSS::Commands::_repo=sub{$repo};
    local *Mediabot::RSS::Commands::_pacing=sub{$pacing};
    local *Mediabot::RSS::Commands::_url_shortener=sub{return sub{$_[0]}};
    local *Mediabot::RSS::Fetcher::fetch_feed_once=sub{$result};
    my %workers=(
        latest=>sub{Mediabot::RSS::Commands::_latest_worker($_[0],'#35+ans','20 Minutes')},
        show=>sub{Mediabot::RSS::Commands::_show_worker($_[0],$_[1],'20 Minutes')},
        probe=>sub{Mediabot::RSS::Commands::_probe_worker($_[0],'https://example.org/rss')},
    );
    for my $command (sort keys %workers) {
        for my $mode ('protected','private','public') {
            $ctx->{channel}=$mode eq 'private' ? undef : $mode eq 'public' ? '#console' : '#35+ans';
            $bot->reset_replies;
            $workers{$command}->($ctx,$mode eq 'public' ? '#console' : '#35+ans');
            my @news=grep {index($_->{text},$url)>=0} @{$bot->{replies}};
            $a->is(scalar @news,1,"mb811: $command/$mode emits exactly one article");
            my $news=$news[0]||{};
            my $public=$mode eq 'public';
            $a->is($news->{type},$public?'privmsg':'notice',"mb811: $command/$mode uses expected transport");
            $a->is($news->{to},$public?'#console':'Teuk',"mb811: $command/$mode preserves destination");
            my $expected=format_rss_announcement(label=>'20 Minutes',title=>$title,url=>$url);
            $expected =~ s/\A\001ACTION (.*)\001\z/$1/s unless $public;
            $a->is($news->{text},$expected,"mb811: $command/$mode preserves title, link and IRC styling");
            $a->ok($public ? ($news->{text}//'') =~ /^\001ACTION .*\001$/s : index($news->{text}//'',"\001")<0,
                "mb811: $command/$mode keeps ACTION only on public news");
        }
    }
    $ctx->{channel}='#35+ans';
    $result->{feed}{items}[0]{title}='Été 🦆 ' x 100;
    $bot->reset_replies;$workers{latest}->($ctx,'#35+ans');
    $a->ok(length(encode('UTF-8',$bot->{replies}[0]{text}))<=400,'mb811: private Unicode article still fits one IRC line');
    $a->ok(index($bot->{replies}[0]{text},"\001")<0,'mb811: long private article has no CTCP envelope');
    my $real=bless {%$bot},'Mediabot';
    my $real_ctx=Mediabot::Context->new(bot=>$real,nick=>'Teuk',channel=>'#35+ans',command=>'rss',args=>[]);
    my ($intents,$truncated,$ok,$err)=Mediabot::CommandAsync::_collect_intents_run(sub{$workers{latest}->($real_ctx,'#35+ans')});
    $a->ok($ok && !$truncated && !defined($err),'mb811: actual async collector completes');
    $a->is(scalar @$intents,1,'mb811: async private preview has one replayable intent');
    $a->is(join('|',@{$intents->[0]}[0,1]),'notice|Teuk','mb811: async replay stays private');
    $a->ok(index($intents->[0][2],"\001")<0,'mb811: async replay carries normal text, not CTCP');
    $a->is(mb811_bytes($pacing->{path}),$before,'mb811: all preview paths preserve quota/history bytes');
};
