package Mediabot::AI::MetaPolicy;
use strict;
use warnings;
use utf8;
use Exporter 'import';
use Mediabot::AI qw(normalize_provider);
our @EXPORT_OK = qw(settings fold clean safe_url wants_web research_kind is_followup is_acknowledgement parse_object);
use JSON::PP ();

sub fold { my $s = lc($_[0] // ''); $s =~ tr/[]\\^/{}|~/; return $s }
sub clean {
    my ($s, $max) = @_;
    return '' unless defined($s) && !ref($s);
    $s =~ s/\x03\d{0,2}(?:,\d{1,2})?//g;
    $s =~ s/[\x00-\x1f\x7f]+/ /g;
    $s =~ s/\s+/ /g; $s =~ s/^\s+|\s+$//g;
    return substr($s, 0, $max // 4000);
}
sub safe_url {
    my ($url) = @_;
    return undef unless defined($url) && !ref($url) && length($url) <= 2048;
    return undef unless $url =~ m{\Ahttps?://([a-z0-9.-]+)(/[^\s\x00-\x1f]*)?\z}i;
    my $host = lc $1;
    return undef unless $host =~ /^[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?\.[a-z]{2,}$/;
    return undef if $host =~ /(?:^|\.)(?:localhost|local|internal|invalid|onion)$/;
    return "$url";
}
sub parse_object {
    my ($text) = @_;
    return undef unless defined($text) && !ref($text) && length($text) <= 30_000;
    $text =~ s/^\s*\x60{3}(?:json)?\s*\n?//; $text =~ s/\n?\x60{3}\s*$//;
    my $obj = eval { JSON::PP->new->decode($text) };
    return ref($obj) eq 'HASH' ? $obj : undef;
}
sub is_followup {
    my $s=lc clean($_[0],500);
    return $s =~ /(?:\A(?:et\b|and\b|what about\b|qu.en est|pour (?:celui|celle|eux)|under\b)|\b(?:celui|celle|ceux|celles|leurs|those|these|its|them|ça|cela)\b)/ ? 1:0;
}
sub is_acknowledgement {
    my $s=lc clean($_[0],2000);
    my $social=qr/(?:salut|bonjour|bonsoir|hello|hi|hey|coucou|merci(?: beaucoup| pour (?:ta|votre|la) réponse)?|thanks(?: a lot| for (?:your|the) answer)?|thank you|ça va|comment vas.tu|tu vas bien|how are you|how.s it going|tu es là|are you there|ok(?:ay)?|oui|non|yes|no|parfait|super|très bien|tres bien|bien reçu|bien recu|d.accord|got it|great|nice|c.est (?:parfait|clair|bien)|ça (?:marche|roule)|je te remercie|j.ai compris)/;
    return $s =~ /\A$social(?:[\s!?.,:;]+$social)*\s*[!?.,:;)]*\z/ ? 1:0;
}
sub _conversation_only {
    my ($s)=@_;
    return 1 if !length($s) || is_acknowledgement($s);
    # Personal recall is conversation context, not a public search target.
    # 'mon code Python' and 'my name server' are ordinary factual requests.
    return 1 if $s =~ /(?:\b(?:mot (?:repère|repere)|repère|repere|code (?:secret|repère|repere)|keyword|codeword)\b)/
        && $s =~ /(?:\b(?:mon|ma|mes|my|our|ton|ta|your)\b|confirme|confirm|retiens|remember)/;
    return 1 if $s =~ /(?:\b(?:je (?:m.appelle|suis né)|mon (?:nom|prénom|prenom|surnom) est|my (?:name|nickname) is)\b|\b(?:t.ai dit|je viens de dire|did i (?:say|tell)|i just (?:said|told)|remember my)\b)/;
    return 1 if $s =~ /\A(?:my word (?:is|was)|what is my word|mon mot (?:est|était|etait))\b/;
    return 1 if $s =~ /\A(?:quel est mon (?:nom|prénom|prenom|surnom)|what is my (?:name|nickname)|tu (?:te souviens|me connais)|do you remember)\b/;
    return 1 if $s =~ /\A(?:écris|ecris|rédige|redige|invente|raconte|traduis|traduire|corrige|reformule|résume|resume|write|compose|invent|translate|rewrite|summari[sz]e)\b/;
    return 1 if $s =~ /\A(?:peux.tu|tu peux|tu pourrais|can you|could you|would you)\s+(?:(?:me|m[’'])\s*)?(?:écrire|ecrire|rédiger|rediger|inventer|raconter|traduire|corriger|reformuler|résumer|resumer|write|compose|invent|translate|rewrite|summari[sz]e)\b/;
    return 1 if $s =~ /\A[\d\s.,+*\/()^%=-]+[?]?\z/;
    return 1 if $s =~ /\A(?:calcule|calculer|calculate|compute|combien font)\s+[\d\s.,+*\/()^%=-]+[?]?\z/;
    my $unit=qr/(?:km|m|cm|mm|mètres?|m[eè]tres?|kilom[eè]tres?|miles?|kg|g|grammes?|kilogrammes?|lb|lbs|pounds?|litres?|liters?|ml|cl|celsius|fahrenheit)/;
    return 1 if $s =~ /\A(?:convertis|convert|convertir)\s+[+-]?[\d.,]+\s*$unit\s+(?:en|in|to)\s+$unit\s*[?.]?\z/;
    return 0;
}
sub research_kind {
    my $s=lc clean($_[0],2000);
    return 'general' if _conversation_only($s);
    return 'cve' if $s =~ /\bcve[- ]20\d{2}[- ]\d{4,10}\b/;
    return 'software' if $s =~ /(?:logiciel|\bsoft\b|software|\bapp(?:lication)?s?\b|\boutil|\btools?\b|programme|alternative)/
        && $s =~ /(?:gratuit|free|open.?source|libre|recommand|recommend|conseill|conseil|meilleur|\bbest\b|alternativ|quel|which|what|choisir|choos)/;
    return 'documentation' if $s =~ /(?:document(?:ation)?|\bapi\b|\bconfigur\w*|\binstall\w*)/
        && $s =~ /(?:comment|how|syntaxe|syntax|param[eè]tre|parameter|option|officiel|official|vérif|verif|check|cherch|search|\bfind\b)/;
    return 'lookup' if $s =~ /(?:sur (?:le )?(?:web|net|internet)|\b(?:google|recherche web|web search)\b|\b(?:cherche|recherche|vérifie|verifie|search|look up|lookup)\b)/;
    # A factual question may be timeless and still need a search. Do not make
    # users add 'recent', a CVE number or an explicit search command.
    return 'lookup' if $s =~ /\A(?:à quoi|a quoi|qui|que|quoi|quel(?:le)?s?|où|ou se|comment|pourquoi|combien|quand|qu.est.ce|est.ce que|what|who|where|which|how|why|when|can you (?:tell|find|explain|recommend)|peux.tu (?:me )?(?:dire|trouver|expliquer|conseiller))\b/;
    return 'lookup' if $s =~ /\A(?:donne.moi|explique|décris|decris|détaille|detaille|tell me|explain|describe|find me|recommend)\b/;
    return 'lookup' if $s =~ m{https?://}i;
    return 'general';
}
sub wants_web {
    my $s=lc clean($_[0],2000);
    return 0 if _conversation_only($s);
    # Addressed informational requests are researched by default, including
    # fragments and informal wording. Topic profiles tune research, not access
    # to it. Contributors may additionally request verification for local tasks.
    return $s =~ /[\p{L}\p{N}]/ ? 1:0;
}
sub settings {
    my ($conf) = @_;
    my $get = sub { my $v = eval { $conf->get('meta_ai.'.$_[0]) }; return $_[1] unless defined $v;
        return join(' ', @$v) if ref($v) eq 'ARRAY'; return ref($v) ? $_[1] : "$v" };
    my $int = sub { my ($k,$d,$lo,$hi)=@_; my $v=$get->($k,$d);
        return $d unless $v =~ /^\d+$/ && $v >= $lo && $v <= $hi; return int $v };
    my %channels = map { fold($_) => 1 } grep { /^#[^\s,:\x00-\x1f]{1,79}$/ }
        split /[\s,]+/, $get->('CHANNELS','');
    my (%seen, @providers);
    for my $raw (split /[\s,]+/, $get->('PROVIDERS','openai anthropic gemini')) {
        my $name=normalize_provider($raw);
        push @providers, $name if defined($name) && $name ne 'auto' && !$seen{$name}++;
    }
    my @domains = grep { /^[a-z0-9][a-z0-9.-]*\.[a-z]{2,}$/i }
        split /[\s,]+/, $get->('PREFERRED_DOMAINS',
        'nist.gov cve.org nvd.nist.gov cisa.gov cert.ssi.gouv.fr cern.ch nasa.gov esa.int insee.fr service-public.gouv.fr legifrance.gouv.fr cyber.gouv.fr cybermalveillance.gouv.fr who.int reuters.com bbc.com franceinfo.fr developers.openai.com platform.claude.com ai.google.dev');
    splice @domains, 32 if @domains > 32;
    return {
        enabled => $int->('ENABLED',0,0,1), channels => \%channels,
        providers => \@providers, min_providers => $int->('MIN_PROVIDERS',2,1,3),
        gemini_fallback => $get->('GEMINI_FALLBACK_MODEL',''),
        models => { openai=>$get->('OPENAI_MODEL','gpt-6.1-sol'),
            anthropic=>$get->('CLAUDE_MODEL','claude-sonnet-5-5'),
            gemini=>$get->('GEMINI_MODEL','gemini-3.8-flash') },
        synthesizer => normalize_provider($get->('SYNTHESIZER','openai')) // 'openai',
        timeout => $int->('TIMEOUT',25,5,45), max_jobs => $int->('MAX_JOBS',2,1,4),
        rate_max => $int->('RATE_MAX',4,1,12), rate_window=>60,
        global_rate_max => $int->('GLOBAL_RATE_MAX',8,1,30),
        daily_limit => $int->('DAILY_LIMIT',100,1,1000),
        memory_turns => $int->('MEMORY_TURNS',12,2,24),
        memory_ttl => $int->('MEMORY_TTL',86400,300,604800),
        state_file => $get->('STATE_FILE',''),
        web => $get->('WEB_MODE','auto') =~ /\A(auto|always|off)\z/ ? $1 : 'auto',
        domains => \@domains, tokens => $int->('MAX_TOKENS',2048,512,8192),
        pacing_us => $int->('SLEEP_US',1500000,1000000,5000000),
    };
}
1;
