package Mediabot::AI::MetaWeb;
use strict;
use warnings;
use HTTP::Tiny;
use JSON::PP ();
use Mediabot::AI::MetaPolicy qw(clean safe_url);
use Mediabot::AI::Transport ();

sub new {
    my ($class,%args)=@_;
    return bless {key=>$args{api_key}//'',domains=>$args{domains}||[],
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
    my ($self,$query)=@_;
    return {ok=>0,error=>'web_not_configured'} unless length $self->{key};
    $query=clean($query,500);
    return {ok=>0,error=>'empty_query'} unless length $query;
    my @sources;my %seen;
    for my $restricted (1,0) {
        my %parameters=(query=>$query,search_depth=>'advanced',max_results=>5,
            include_answer=>JSON::PP::false,include_published_date=>JSON::PP::true,
            exclude_domains=>[qw(facebook.com instagram.com tiktok.com pinterest.com)]);
        $parameters{include_domains}=$self->{domains} if $restricted && @{$self->{domains}};
        my $data=$self->_post('search',\%parameters);
        next unless $data && ref($data->{results}) eq 'ARRAY';
        for my $row (@{$data->{results}}) {
            next unless ref($row) eq 'HASH';my $url=safe_url($row->{url});
            next unless $url && !$seen{$url}++;
            my $text=clean($row->{content},2000);next unless length($text)>=40;
            push @sources,{id=>scalar(@sources)+1,url=>$url,title=>clean($row->{title},140),
                text=>$text,date=>clean($row->{published_date},80),kind=>'search_excerpt'};
            last if @sources>=3;
        }
        last if @sources>=2 || !$restricted;
    }
    return {ok=>0,error=>'web_no_evidence'} unless @sources;
    my $extracted=$self->_post('extract',{urls=>[map {$_->{url}} @sources],
        extract_depth=>'basic',format=>'text'});
    if ($extracted && ref($extracted->{results}) eq 'ARRAY') {
        my %by_url=map {$_->{url}=>$_} @sources;
        for my $row (@{$extracted->{results}}) {
            next unless ref($row) eq 'HASH';my $url=safe_url($row->{url});
            next unless $url && exists $by_url{$url};
            my $text=clean($row->{raw_content},5000);next unless length($text)>=80;
            $by_url{$url}{text}=$text;$by_url{$url}{kind}='page_excerpt';
        }
    }
    return {ok=>1,sources=>\@sources};
}
1;
