package Mediabot::AI::MetaWeb;
use strict;
use warnings;
use HTTP::Tiny;
use JSON::PP ();
use Mediabot::AI::MetaPolicy qw(clean safe_url);
use Mediabot::AI::Transport ();
use Mediabot::AI::MetaEvidence qw(research_plan select_sources select_passages);
use POSIX qw(strftime);
use Time::Local qw(timegm);

sub new {
    my ($class,%args)=@_;
    return bless {key=>$args{api_key}//'',domains=>$args{domains}||[],clock=>$args{clock}||sub {time},
        http_factory=>$args{http_factory}||sub {HTTP::Tiny->new(timeout=>8,
            verify_SSL=>1,max_size=>512*1024,max_redirect=>0,agent=>'Mediabot-MetaWeb/1.0')}},$class;
}
sub _post {
    my ($self,$endpoint,$data)=@_;
    my $response=Mediabot::AI::Transport::post_json(
        api_url=>'https://api.tavily.com/'.$endpoint,timeout=>8,
        headers=>{'Content-Type'=>'application/json',Authorization=>'Bearer '.$self->{key}},
        payload=>JSON::PP->new->utf8->encode($data),http_factory=>$self->{http_factory});
    return undef unless $response->{success};
    my $body=Mediabot::AI::Transport::decode_content($response);
    return undef if length($body)>512*1024;
    my $parsed=eval {JSON::PP->new->utf8->decode($body)};
    return ref($parsed) eq 'HASH' ? $parsed : undef;
}
sub search {
    my ($self,$query,%args)=@_;
    return {ok=>0,error=>'web_not_configured'} unless length $self->{key};
    $query=clean($query,500);
    return {ok=>0,error=>'empty_query'} unless length $query;
    my $plan=ref($args{plan}) eq 'HASH'?$args{plan}:research_plan(prompt=>$query,
        date=>strftime('%Y-%m-%d',gmtime($self->{clock}->())),domains=>$self->{domains});
    my @rows;my $sources=[];
    for my $restricted (1,0) {
        my $search_query=$restricted?$query:clean($plan->{alternate_query}//$query,500);
        my %parameters=(query=>$search_query,search_depth=>'advanced',max_results=>5,
            include_answer=>JSON::PP::false,include_published_date=>JSON::PP::true,
            exclude_domains=>[qw(facebook.com instagram.com tiktok.com pinterest.com)]);
        $parameters{include_domains}=$plan->{domains} if $restricted && @{$plan->{domains}||[]};
        if (defined($plan->{start_date})) {
            $parameters{start_date}=$plan->{start_date};
            $parameters{filter_by_published_date}=JSON::PP::true;
            my ($y,$m,$d)=split /-/,$plan->{end_date}//$plan->{as_of};
            $parameters{end_date}=strftime('%Y-%m-%d',gmtime(timegm(0,0,12,$d,$m-1,$y)+86400));
        }
        my $data=$self->_post('search',\%parameters);
        next unless $data && ref($data->{results}) eq 'ARRAY';
        my @batch=@{$data->{results}};splice @batch,5 if @batch>5;
        push @rows,@batch;
        $sources=select_sources(\@rows,$plan);
        my $useful=grep {$_->{_hits} && (!defined($plan->{start_date}) || $_->{date_status} eq 'dated')} @$sources;
        last if (@$sources>=2 && $useful) || !$restricted;
    }
    return {ok=>0,error=>'web_no_evidence'} unless @$sources;
    my $extracted=$self->_post('extract',{urls=>[map {$_->{url}} @$sources],
        extract_depth=>'basic',format=>'text',query=>$query,chunks_per_source=>3});
    if ($extracted && ref($extracted->{results}) eq 'ARRAY') {
        my %by_url=map {$_->{url}=>$_} @$sources;
        for my $row (@{$extracted->{results}}) {
            next unless ref($row) eq 'HASH';my $url=safe_url($row->{url});
            next unless $url && exists $by_url{$url};
            my $text=select_passages($row->{raw_content},$query);next unless length($text)>=80;
            $by_url{$url}{text}=$text;$by_url{$url}{kind}='page_excerpt';
        }
    }
    for my $source (@$sources) {delete $source->{$_} for qw(_score _host _index _hits)}
    return {ok=>1,sources=>$sources};
}
1;
