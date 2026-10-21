package Mediabot::AI::MetaReply;
use strict;
use warnings;
use Mediabot::IRC::TextBudget qw(_utf8_text_bytes);
use utf8;
use Exporter 'import';
use Mediabot::AI::MetaPolicy qw(clean safe_url);
use Mediabot::URLShortener qw(make_bot_shortener);
use Mediabot::AI::IRCOutput qw(format_ai_reply);
our @EXPORT_OK=qw(clean_answer format_meta_reply shorten_sources display_urls shorturl_ready source_label);

sub source_label {
    my ($url)=@_;
    $url=safe_url($url);return '' unless defined $url;
    my ($host)=$url=~m{\Ahttps?://([^/]+)}i;
    $host=lc $host;$host=~s/\Awww\.//;
    # Labels describe the original source site, never a model-supplied title
    # or the shortener. More specific domains precede their parent site.
    for my $site (
        ['cert.ssi.gouv.fr','CERT-FR'],
        ['ssi.gouv.fr','ANSSI'],
        ['cybermalveillance.gouv.fr','Cybermalveillance.gouv.fr'],
        ['franceinfo.fr','FranceInfo'],
        ['francetvinfo.fr','FranceInfo'],
        ['lemonde.fr','Le Monde'],
        ['reuters.com','Reuters'],
        ['bbc.com','BBC'],
        ['bbc.co.uk','BBC'],
        ['wikipedia.org','Wikipedia'],
        ['github.com','GitHub'],
        ['home-assistant.io','Home Assistant'],
        ['musee-orsay.fr',"Musée d'Orsay"],
    ) {
        my ($domain,$label)=@$site;
        return $label if $host eq $domain || $host=~/\.\Q$domain\E\z/;
    }
    # Unknown sites retain their host, including meaningful subdomains.
    # For unusually long names keep the domain ending, not a misleading prefix.
    return length($host)>48?'...'.substr($host,-45):$host;
}

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

sub format_meta_reply {
    my ($answer)=@_;
    my $lines=format_ai_reply(clean_answer($answer),max_lines=>2,wrap_bytes=>400,truncation_suffix=>' …');
    return $lines unless @$lines==2 && _utf8_text_bytes($lines->[1])<60;
    return $lines if join('',@$lines) =~ /[\x00-\x1f]/;
    my ($first,$last)=@$lines;
    # Prefer a whole final sentence, otherwise move complete words. Preserve
    # content and the two-line wire envelope; do not touch styled replies.
    if ($first =~ /\A(.+[.!?])\s+([^.!?]+)\z/s) {
        my ($prefix,$suffix)=($1,$2);my $candidate="$suffix $last";
        return [$prefix,$candidate] if _utf8_text_bytes($candidate)<=400;
    }
    my @words=split / /,$first;
    while (@words>3 && _utf8_text_bytes($last)<140) {
        my $word=pop @words;
        if (_utf8_text_bytes("$word $last")>400) {push @words,$word;last}
        $last="$word $last";
    }
    return [join(' ',@words),$last];
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
