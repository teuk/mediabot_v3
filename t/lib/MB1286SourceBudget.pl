use strict;
use warnings;
use utf8;
use Test::More;
use Encode qw(encode);
use Mediabot::AI::MetaReply qw(shorten_sources display_urls source_requires_shortening);
return sub {
    my $prefix='https://example.org/';
    my @urls=map {$prefix.('x'x($_-length($prefix)))} (139,140,141);
    is_deeply([map {source_requires_shortening($_)} @urls],[0,0,1],
        '139/140-byte URLs stay original; 141 bytes triggers shortening');
    my $wide=$prefix.('é'x61); # 142 UTF-8 bytes, fewer characters
    is(source_requires_shortening($wide),1,'UTF-8 bytes rather than characters govern the threshold');
    is_deeply([map {source_requires_shortening($_)} (undef,{},'javascript:bad')],[0,0,0],
        'invalid sources never qualify');
    my ($factories,@calls);my $result='https://short.example.org/shorturl/Abcdef23';
    no warnings 'redefine';
    local *Mediabot::AI::MetaReply::make_bot_shortener=sub {
        $factories++;return sub {push @calls,$_[0];die "offline\n" if $result eq 'throw';return $result};
    };
    my $sources=[map {{url=>$_}} @urls[0,1]];
    my $r=shorten_sources(sources=>$sources);
    is($factories//0,0,'all-short batch does not create the shortener');
    is(scalar @calls,0,'all-short batch makes no shortening calls');
    is_deeply($r,{mappings=>[map {{url=>$_,display_url=>$_}} @urls[0,1]],events=>[]},
        'short destinations and order are preserved exactly');
    $sources=[{url=>$urls[0]},{url=>$urls[2]},{url=>$wide}];
    $r=shorten_sources(sources=>$sources);
    is_deeply(\@calls,[$urls[2]],'mixed batch shortens only the long source within the two-source cap');
    is_deeply([map {$_->{display_url}} @{$r->{mappings}}],[$urls[0],$result],
        'mixed batch retains original and alias in citation order');
    @calls=();
    $r=shorten_sources(sources=>[{}, {url=>$urls[2]}, {url=>$urls[2]}, {url=>$wide}]);
    is_deeply(\@calls,[$urls[2],$wide],'invalid and duplicate sources do not consume the two-source limit');
    for my $bad ('throw',undef,'',{},$urls[2],$urls[2].'longer') {
        $result=$bad;
        # Avoid comparing reference/undef in the fake service itself.
        local *Mediabot::AI::MetaReply::make_bot_shortener=sub {
            return sub {die "offline\n" if defined($result) && !ref($result) && $result eq 'throw';return $result};
        };
        my $fallback=shorten_sources(sources=>[{url=>$urls[2]}]);
        is($fallback->{mappings}[0]{display_url},$urls[2],
            'failed, malformed or non-beneficial shortening keeps the exact original');
    }
    my $alias='https://short.example.org/shorturl/Abcdef23';
    my $map=display_urls($sources,{mappings=>[
        {url=>$urls[0],display_url=>$alias},{url=>$urls[2],display_url=>$alias}
    ]},'https://short.example.org/shorturl/');
    is_deeply($map,{$urls[0]=>$urls[0],$urls[2]=>$alias},
        'parent presentation refuses aliases for short URLs even from a supplied result');
    my $large_base='https://'.('subdomain.'x15).'example.org/shorturl/';
    $map=display_urls([{url=>$urls[2]}],{mappings=>[
        {url=>$urls[2],display_url=>$large_base.'Abcdef23'}]},$large_base);
    is($map->{$urls[2]},$urls[2],'parent rejects a valid service alias longer than the original');
    $map=display_urls([{url=>$urls[2]}],{mappings=>[
        {url=>$urls[2],display_url=>'https://foreign.example.org/Abcdef23'}]},'https://short.example.org/shorturl/');
    is_deeply($map,{},'foreign aliases remain rejected');

    # Load exact runtime methods without the unrelated Helpers dependency graph.
    open my $f,'<','Mediabot/AI/MetaRuntime.pm' or die $!;
    my $src=do {local $/;<$f>};close $f;
    my $code='package MB1286Runtime; use strict; use warnings; use Mediabot::IRC::TextBudget qw(_utf8_text_bytes); use Mediabot::AI::MetaPolicy qw(safe_url); use Mediabot::AI::MetaReply qw(source_label source_requires_shortening shorturl_ready);';
    for my $name (qw(_source_line _present_sources)) {
        my ($body)=$src=~/^(sub \Q$name\E \{.*?)(?=^sub \w+|\z)/ms;
        die "missing $name" unless $body;$code.=$body;
    }
    eval $code;die $@ if $@;
    my $host=('a'x36).'.example.org'; # 48-byte label
    my $u='https://'.$host.'/';$u.='x'x(140-length($u));
    my $line=MB1286Runtime::_source_line([{url=>$u},{url=>$u.'?'}],'fr',{});
    cmp_ok(length(encode('UTF-8',$line)),'<=',400,'two boundary-length labelled sources fit the wire budget');
    $line=MB1286Runtime::_source_line([{url=>$u},{url=>substr($u,0,-1).'y'}],'fr',{});
    is(length(encode('UTF-8',$line)),399,'two 140-byte URLs and maximum labels consume exactly 399 bytes');
    like($line,qr/\Q$u\E/,'original URL stays complete and clickable');
    my ($done,$value)=(0,undef);
    local *MB1286Runtime::shorturl_ready=sub {die 'short batch should not inspect service configuration'};
    my $runtime=bless {},'MB1286Runtime';
    my $ok=eval {$runtime->_present_sources([{url=>$urls[0]},{url=>$urls[1]}],sub {$done++;$value=shift});1};
    ok($ok,'all-short presentation finishes without configuration, event loop or worker');
    is($done,1,'all-short completion occurs exactly once');
    is_deeply($value,{},'runtime fallback mapping preserves original sources');
};
