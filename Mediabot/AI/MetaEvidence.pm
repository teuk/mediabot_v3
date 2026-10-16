package Mediabot::AI::MetaEvidence;
use strict;
use warnings;
use utf8;
use Exporter 'import';
use POSIX qw(strftime);
use Time::Local qw(timegm);
use Unicode::Normalize qw(NFC);
use Date::Parse qw(str2time);
use Mediabot::AI::MetaPolicy qw(clean safe_url research_kind is_followup is_acknowledgement);
our @EXPORT_OK=qw(research_plan select_sources select_passages validate_support);

sub _date {
    my ($value)=@_;
    if (defined($value) && !ref($value) && length($value)<=80
        && $value =~ /\A[A-Za-z]{3}, \d{1,2} [A-Za-z]{3} \d{4} \d{2}:\d{2}:\d{2} (?:GMT|UTC|[+-]\d{4})\z/) {
        my $epoch=eval {str2time($value,'UTC')};
        return defined($epoch)?_date(strftime('%Y-%m-%d',gmtime($epoch))):undef;
    }
    return undef unless defined($value) && !ref($value)
        && $value =~ /\A(\d{4})-(\d{2})-(\d{2})(?:[T\s].*)?\z/;
    my ($y,$m,$d)=($1,$2,$3);
    return undef unless $y>=1970 && $y<=2099 && $m>=1 && $m<=12 && $d>=1 && $d<=31;
    my $epoch=eval {timegm(0,0,12,$d,$m-1,$y)};
    return undef if $@ || !defined($epoch);
    my $day=strftime('%Y-%m-%d',gmtime($epoch));
    return $day eq sprintf('%04d-%02d-%02d',$y,$m,$d)?$day:undef;
}
sub _terms {
    my ($text)=@_;my %stop=map {$_=>1} qw(the and for with from that this what when how about latest current official recent recently today version search quelle quelles quel quels comment quand pour avec dans cette cela ceci sujet des les une est sont sur que qui moi donne plus aujourd hui dernier derniers derniere dernieres actuel actuelles recemment récent récentes);
    my %seen;my @words=grep {length($_)>=3 && !$stop{$_} && !$seen{$_}++}
        lc(clean($text,1000)) =~ /[\p{L}\p{N}]+/g;
    splice @words,24 if @words>24;
    return \@words;
}
sub _hits {
    my ($text,$terms)=@_;my $hay=lc($text//'' );my $count=0;
    $count++ for grep {$hay =~ /(?<![\p{L}\p{N}])\Q$_\E(?![\p{L}\p{N}])/} @$terms;
    return $count;
}
sub research_plan {
    my (%args)=@_;my $prompt=clean($args{prompt},500);
    my $date=_date($args{date})//strftime('%Y-%m-%d',gmtime(time));
    my (%seen,@queries);
    for my $draft (@{ref($args{drafts}) eq 'ARRAY'?$args{drafts}:[]}) {
        next unless ref($draft) eq 'HASH';my $query=clean($draft->{query},500);
        push @queries,$query if length($query) && !$seen{lc $query}++;
    }
    my $context='';
    if (ref($args{messages}) eq 'ARRAY' && @{$args{messages}}>1) {
        for my $message (reverse @{$args{messages}}[0..$#{$args{messages}}-1]) {
            next unless ref($message) eq 'HASH' && ($message->{role}//'') eq 'user';
            $context=clean($message->{content},500);
            $context =~ s/\Aspeaker\d+(?: \([^)]*\))?:\s*//;
            $context =~ s{https?://\S+}{}g;
            if (is_acknowledgement($context)) {$context='';next}
            last;
        }
    }
    my $followup=is_followup($prompt);
    my $fallback=clean(($followup && length($context)?"$context — ":'').$prompt,500);
    my $kind=research_kind($prompt);
    # Resolve short follow-ups from the previous user question only. Assistant
    # claims and model-proposed identifiers cannot replace the user's target.
    my $target=$prompt;
    if ($followup && length($prompt)<160 && length($context)) {
        $target="$context $prompt";$kind=research_kind($target);
    }
    my %ids;my @ids;
    while ($target =~ /\bCVE[- ](20\d{2})[- ](\d{4,10})\b/gi) {
        my $id="CVE-$1-$2";push @ids,$id unless $ids{$id}++;last if @ids>=3;
    }
    my $query=$queries[0]//$fallback;
    my $alternate=$queries[1]//$fallback;
    $alternate=$query unless length($alternate);
    if (@ids) {
        my $prefix=join(' ',@ids);
        for ($query,$alternate) {
            # Retain the exact requested CVE even when contributors return a
            # generic query or substitute a different vulnerability number.
            s/\bCVE[- ]20\d{2}[- ]\d{4,10}\b//gi;
            $_=clean("$prefix $_",500);
        }
    }
    my $period=lc $prompt;my $start;
    # Recency of the answer is not recency of the page's publication. Opening
    # hours, rules, prices and reference facts can use older official pages.
    my $publication_request=$period =~ /(?:actualité|actualite|\bnews\b|articles?|rapports?|reports?|études?|etudes?|studies|incidents?|\bcas\b|\bcases?\b|exemples?|examples?|publications?|publié|publie|published|paru|released|quoi de neuf|what.s new)/;

    my $days=$period =~ /(?:aujourd.hui|\btoday\b)/?0
        :$period =~ /(?:cette semaine|\bthis week\b)/?7
        :$period =~ /(?:ce mois|\bthis month\b|récent|recent|récemment|recemment)/?30:undef;
    if (defined($days) && $publication_request) {
        my ($y,$m,$d)=split /-/,$date;
        $start=strftime('%Y-%m-%d',gmtime(timegm(0,0,12,$d,$m-1,$y)-86400*$days));
    }
    my $end=$date;
    if ($period =~ /(?:publié(?:e|s|es)?|publie(?:e|s|es)?|paru(?:e|s|es)?|published|released)\s+(?:en|in)\s+(20\d\d)/
        && $1<=substr($date,0,4)) {
        my $year=$1;$start="$year-01-01";$end="$year-12-31";
        $end=$date if $end gt $date;
    }
    my @domains=grep {!ref($_) && /^[a-z0-9][a-z0-9.-]*\.[a-z]{2,}$/i}
        @{ref($args{domains}) eq 'ARRAY'?$args{domains}:[]};
    @domains=map {lc $_} @domains;splice @domains,32 if @domains>32;
    my $topic=lc "$prompt $query";my @specific;
    @specific=qw(cyber.gouv.fr cybermalveillance.gouv.fr) if $topic =~ /(?:anssi|phishing|hameçonnage|cyber)/;
    @specific=qw(developers.openai.com platform.openai.com) if $topic =~ /\bopenai\b/;
    @specific=qw(insee.fr) if $topic =~ /\binsee\b/;
    @specific=qw(cern.ch) if $topic =~ /\bcern\b/;
    @specific=qw(nasa.gov) if $topic =~ /\bnasa\b/;
    my %configured=map {$_=>1} @domains;
    @specific=grep {$configured{$_}} @specific;
    @specific=grep {$configured{$_}} qw(cve.org nvd.nist.gov cisa.gov cert.ssi.gouv.fr) if $kind eq 'cve';
    return {query=>$query,alternate_query=>$alternate,as_of=>$date,end_date=>$end,
        kind=>$kind,identifiers=>\@ids,domain_mode=>'prefer',
        (defined($start)?(start_date=>$start):()),domains=>@specific?\@specific:\@domains};
}
sub select_sources {
    my ($rows,$plan)=@_;return [] unless ref($rows) eq 'ARRAY' && ref($plan) eq 'HASH';
    my $terms=_terms($plan->{query});my @candidates;my %best;my $index=0;
    for my $row (@$rows) {
        last if $index++>=20;
        next unless ref($row) eq 'HASH';my $url=safe_url($row->{url});
        next unless $url;
        my $text=clean($row->{content}//$row->{text},2000);
        next unless length($text)>=40;
        my $rawdate=$row->{published_date}//$row->{date};
        my $date=_date($rawdate);
        next if defined($date) && ($date gt ($plan->{end_date}//$plan->{as_of}) || $date gt $plan->{as_of}
            || (defined($plan->{start_date}) && $date lt $plan->{start_date}));
        my $title=clean($row->{title},140);my ($host)=$url =~ m{^https?://([^/]+)}i;
        if (@{$plan->{identifiers}||[]}) {
            my $identity="$title $text $url";
            next unless grep {$identity =~ /(?<![A-Za-z0-9])\Q$_\E(?![A-Za-z0-9])/i} @{$plan->{identifiers}};
        }
        $host=lc($host//'');$host =~ s/^www\.//;
        my $primary=grep {$host eq $_ || $host =~ /\.\Q$_\E\z/} @{$plan->{domains}||[]};
        my $hits=_hits("$title $text",$terms);
        my $score=8*$hits+($primary?5:0)+(defined($date)?3:0);
        my $candidate={url=>$url,title=>$title,text=>$text,date=>$date//'',
            kind=>'search_excerpt',date_status=>defined($date)?'dated':'unknown',retrieved=>$plan->{as_of},
            _score=>$score,_host=>$host,_index=>$index,_hits=>$hits};
        $best{$url}=$candidate if !exists($best{$url}) || $score>$best{$url}{_score}
            || ($score==$best{$url}{_score} && ($date//'') gt $best{$url}{date});
    }
    @candidates=values %best;
    @candidates=sort {$b->{_score}<=>$a->{_score} || $b->{date} cmp $a->{date}
        || $a->{_index}<=>$b->{_index}} @candidates;
    my (%hosts,@selected,@deferred);
    for my $row (@candidates) {
        if (($hosts{$row->{_host}}//0)>=2) {push @deferred,$row;next}
        $hosts{$row->{_host}}++;push @selected,$row;
        last if @selected>=3;
    }
    push @selected,shift @deferred while @selected<3 && @deferred;
    for my $i (0..$#selected) {$selected[$i]{id}=$i+1}
    return \@selected;
}
sub select_passages {
    my ($raw,$query)=@_;return '' unless defined($raw) && !ref($raw);
    # Preserve complete relevant sentence/paragraph fragments instead of
    # feeding only a site's navigation and first 5000 characters.
    $raw=substr($raw,0,40_000);my $terms=_terms($query);my @parts;my $index=0;
    for my $part (split /(?:\n+|(?<=[.!?])\s+)/,$raw) {
        next unless length $part;
        while (length($part)>900) {my $piece=substr($part,0,900,'');push @parts,{text=>clean($piece,900),index=>$index++}}
        $part=clean($part,900);next unless length $part;
        push @parts,{text=>$part,index=>$index++};
    }
    $_->{hits}=_hits($_->{text},$terms) for @parts;
    return clean($raw,5000) unless grep {$_->{hits}} @parts;
    @parts=sort {$b->{hits}<=>$a->{hits} || $a->{index}<=>$b->{index}} @parts;
    my (@chosen,$length);
    for my $part (@parts) {
        next if ($length//0)+length($part->{text})+3>5000;
        push @chosen,$part;$length+=length($part->{text})+3;
        last if @chosen>=6;
    }
    @chosen=sort {$a->{index}<=>$b->{index}} @chosen;
    return join(' … ',map {$_->{text}} @chosen);
}
sub _literal {
    my $text=NFC(clean($_[0],6000));
    $text =~ tr/‘’/''/;$text =~ tr/“”/""/;
    return $text;
}
sub validate_support {
    my ($parsed,$cited)=@_;
    return 'missing' unless ref($parsed) eq 'HASH'
        && exists($parsed->{support}) && exists($parsed->{basis});
    return 'invalid' unless !ref($parsed->{basis}) && defined($parsed->{basis})
        && $parsed->{basis} =~ /\A(?:supported|partial|insufficient)\z/
        && ref($parsed->{support}) eq 'ARRAY' && @{$parsed->{support}}<=2;
    return 'missing' unless @{$parsed->{support}};
    my %source=map {$_->{id}=>$_} @$cited;my %seen;
    for my $anchor (@{$parsed->{support}}) {
        return 'invalid' unless ref($anchor) eq 'HASH'
            && defined($anchor->{source_id}) && !ref($anchor->{source_id})
            && $anchor->{source_id} =~ /^[1-3]$/ && exists($source{$anchor->{source_id}})
            && !$seen{$anchor->{source_id}}++ && defined($anchor->{quote}) && !ref($anchor->{quote})
            && length($anchor->{quote})>=12 && length($anchor->{quote})<=240;
        my $needle=_literal($anchor->{quote});my $hay=_literal($source{$anchor->{source_id}}{text});
        return 'mismatch' unless length($needle)>=12 && index($hay,$needle)>=0;
    }
    return 'missing' if grep {!$seen{$_->{id}}} @$cited;
    return undef;
}
1;
