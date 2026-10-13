package Mediabot::AI::MetaPolicy;
use strict;
use warnings;
use utf8;
use Exporter 'import';
use Mediabot::AI qw(normalize_provider);
our @EXPORT_OK = qw(settings fold clean safe_url wants_web parse_object);
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
sub wants_web {
    my ($s) = @_;
    return clean($s) =~ /(?:aujourd.hui|actuel\w*|récent\w*|recent\w*|derni[eè]r\w*|maintenant|cette semaine|en ce moment|today|currently|current|latest|this week|now|prix|price|météo|weather|président|president|premier ministre|prime minister|ceo|horaire|schedule|version|résultat|result|202[6-9]|\b20[3-9]\d\b)/i ? 1 : 0;
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
        'nist.gov cern.ch nasa.gov esa.int insee.fr service-public.gouv.fr legifrance.gouv.fr who.int reuters.com bbc.com franceinfo.fr developers.openai.com platform.claude.com ai.google.dev');
    splice @domains, 32 if @domains > 32;
    return {
        enabled => $int->('ENABLED',0,0,1), channels => \%channels,
        providers => \@providers, min_providers => $int->('MIN_PROVIDERS',2,1,3),
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
