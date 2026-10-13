package Mediabot::AI::MetaReply;
use strict;
use warnings;
use utf8;
use Exporter 'import';
use Mediabot::AI::MetaPolicy qw(clean safe_url);
use Mediabot::URLShortener qw(make_bot_shortener);
our @EXPORT_OK=qw(clean_answer shorten_sources display_urls shorturl_ready);

sub shorturl_ready {
    my ($bot)=@_;
    return 0 unless $bot && ref($bot->{conf});
    my $get=sub {my $v=eval {$bot->{conf}->get('shorturl.'.$_[0])};return defined($v) && !ref($v)?$v:''};
    my ($api,$base)=Mediabot::URLShortener::_service_contract($get->('API_URL'),$get->('PUBLIC_BASE_URL'));
    return length($api) && length($base) && length(Mediabot::URLShortener::_api_key($get->('API_KEY'))) ? 1:0;
}

sub clean_answer {
    my ($text,$max)=@_;
    return '' unless defined($text) && !ref($text);
    # Normalize accidental serialized line breaks in provider prose only.
    # Keep ambiguous path/code sequences such as C:\new intact. Incoming
    # questions, web extracts, source URLs and legacy replies are untouched.
    $text =~ s/(?:\\+r)?\\+n(?=\s|[-*\x{2022}]|$)/\n/g;
    $text =~ s/\\+[rt](?=\s|$)/ /g;
    $text =~ s/\r\n?/\n/g;
    $text =~ s/\s*\n\s*[-*\x{2022}]\s+/; /g;
    $text =~ s/:\s*;\s*/: /g;
    $text =~ s/([.!?])\s*;\s*/$1 /g;
    return clean($text,$max//1600);
}

sub shorten_sources {
    my (%args)=@_;my $sources=$args{sources};
    return {mappings=>[],events=>[]} unless ref($sources) eq 'ARRAY';
    my @events;
    my $shorten=make_bot_shortener(bot=>$args{bot},allow_legacy=>0,
        (exists($args{http})?(http=>$args{http}):()),
        on_event=>sub {push @events,$_[0] if ref($_[0]) eq 'HASH' && @events<4});
    my (@mappings,%seen);
    for my $source (@$sources) {
        next unless ref($source) eq 'HASH';my $url=safe_url($source->{url});
        next unless $url && !$seen{$url}++;
        my $display=eval {$shorten->($url)};
        $display=$url unless defined($display) && !ref($display) && length($display);
        push @mappings,{url=>$url,display_url=>$display};
        last if @mappings>=2;
    }
    return {mappings=>\@mappings,events=>\@events};
}

sub display_urls {
    my ($sources,$result,$base)=@_;
    my %allowed=map {ref($_) eq 'HASH' && safe_url($_->{url}) ? ($_->{url}=>1):()} @$sources;
    my %urls;
    return \%urls unless ref($result) eq 'HASH' && ref($result->{mappings}) eq 'ARRAY';
    $base=Mediabot::URLShortener::_public_base($base);
    for my $mapping (@{$result->{mappings}}) {
        next unless ref($mapping) eq 'HASH';
        my $original=$mapping->{url};my $display=$mapping->{display_url};
        next unless defined($original) && !ref($original) && $allowed{$original};
        next unless defined($display) && !ref($display) && safe_url($display);
        next unless $display eq $original || (length($base)
            && $display =~ m{\A\Q$base\E[23456789A-HJ-NP-Za-km-z]{8,16}\z});
        $urls{$original}=$display;
    }
    return \%urls;
}
1;
