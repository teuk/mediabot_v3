use strict;
use warnings;
use utf8;
use Test::More;
use Encode qw(encode);
use File::Temp qw(tempfile);
use JSON::PP ();
use IO::Async::Loop;
use Time::HiRes ();
use Mediabot::External ();
use Mediabot::External::URL ();

binmode Test::More->builder->output, ':encoding(UTF-8)';
binmode Test::More->builder->failure_output, ':encoding(UTF-8)';
{
    package MB1013::Log;
    sub log { 1 }
    package MB1013::HTTP;
    sub get {
        my ($self,$url) = @_;
        push @{$self->{calls}}, $url;
        if ($self->{path}) {
            open my $fh, '>>:raw', $self->{path} or die $!;
            print {$fh} JSON::PP::encode_json({url=>$url})."\n" or die $!;
            close $fh or die $!;
        }
        return {success=>0,status=>404,reason=>'offline fixture'} if $url =~ m{/oembed\?};
        return {success=>1,status=>200,content=>encode('UTF-8', $self->{html})}
            if $url =~ m{\Ahttps://open\.spotify\.com/embed/track/AbCd1234\z};
        return {success=>1,status=>200,content=>'<title>Spotify</title>'}
            if $url eq 'https://open.spotify.com/track/AbCd1234';
        die 'unexpected HTTP destination in offline fixture';
    }
}
sub MB1013::HTTP::encode { goto &Encode::encode }
my $log = bless {}, 'MB1013::Log';
sub metadata_1388 {
    my ($html,$initial) = @_;
    my %info = (type=>'track', %{$initial // {}});
    my $saved = $html;
    my (@warnings,$error);
    {
        local $SIG{__WARN__} = sub { push @warnings, @_ };
        $error = eval {
            Mediabot::External::_spotify_extract_meta({logger=>$log},\%info,$html,'offline'); 1;
        } ? '' : "$@";
    }
    return [\%info, $html eq $saved ? 1 : 0, \@warnings, $error];
}
sub expected_1388 { return [{type=>'track', %{$_[0]}},1,[],''] }
{
    my (@actual,@expected);
    for my $row (
        [q{<meta property="og:title" content="L'amour - Toto">}, {title=>"L'amour",artist=>'Toto'}],
        [q{<meta name='twitter:title' content='Rock "Live" - Studio'>}, {title=>'Rock "Live"',artist=>'Studio'}],
        [q{<meta property="og:title" content="Départ d'ici - Renaud">}, {title=>"Départ d'ici",artist=>'Renaud'}],
    ) {
        push @actual, metadata_1388($row->[0]);
        push @expected, expected_1388($row->[1]);
    }
    is_deeply(\@actual,\@expected,'apostrophes and opposite quotation marks remain inside complete title/artist values');
}
{
    my (@actual,@expected);
    for my $html (
        q{<META CONTENT = "Good song - Studio" PROPERTY = 'OG:TITLE'>},
        q{<meta data-note='ignore content="Wrong"' content="Good song - Studio" name="twitter:title">},
        q{<meta property="og:title" content="Good song - Studio" content="Wrong">},
    ) {
        push @actual, metadata_1388($html);
        push @expected, expected_1388({title=>'Good song',artist=>'Studio'});
    }
    is_deeply(\@actual,\@expected,'attribute order, whitespace, case and unrelated attribute text cannot select the wrong content');
}
is_deeply(metadata_1388(q{<meta property="og:title" content="Love > Hate - Studio">}),
    expected_1388({title=>'Love > Hate',artist=>'Studio'}),
    'a greater-than sign inside a quoted value does not terminate the meta tag');
{
    my (@actual,@expected);
    for my $key ('og:description','description','twitter:description') {
        my $html = qq{<meta property="og:title" content="My song"><meta name="$key" content="Song - Guns N' Roses - 2020">};
        push @actual, metadata_1388($html);
        push @expected, expected_1388({title=>'My song',artist=>"Guns N' Roses",year=>'2020'});
    }
    is_deeply(\@actual,\@expected,'all description sources retain the complete artist and year after an apostrophe');
}
my $html = q{<meta property="og:title" content="L'amour - Guns N' Roses">};
my $clean_url = 'https://open.spotify.com/track/AbCd1234';
my $urls = [
    'https://open.spotify.com/oembed?url=https%3A%2F%2Fopen.spotify.com%2Ftrack%2FAbCd1234',
    'https://open.spotify.com/embed/track/AbCd1234',
];
{
    my $http = bless {calls=>[],html=>$html}, 'MB1013::HTTP';
    no warnings qw(redefine once);
    local *Mediabot::External::_make_http = sub { $http };
    local *Mediabot::External::_fetch_url_chromium_dumpdom = sub { die 'unexpected Chromium' };
    my (@warnings,$info,$error);
    {
        local $SIG{__WARN__} = sub { push @warnings, @_ };
        $error = eval {
            $info = Mediabot::External::Spotify::_spotify_fetch_sync({logger=>$log},$clean_url,'track','AbCd1234'); 1;
        } ? '' : "$@";
    }
    is_deeply([$error,\@warnings,$info,$http->{calls}],
        ['',[],{type=>'track',title=>"L'amour",artist=>"Guns N' Roses"},$urls],
        'real lightweight fetch keeps full metadata and avoids an unnecessary third HTTP fallback');
}
{
    my ($fh,$path) = tempfile(UNLINK=>1); close $fh;
    my $http = bless {calls=>[],html=>$html,path=>$path}, 'MB1013::HTTP';
    my $bot = {logger=>$log,loop=>IO::Async::Loop->really_new,out=>[]};
    my (@warnings,$error,$handled,$before);
    no warnings qw(redefine once);
    local *Mediabot::External::_make_http = sub { $http };
    local *Mediabot::External::_chanset_ok = sub { 1 };
    local *Mediabot::External::_fetch_url_chromium_dumpdom = sub { die 'unexpected Chromium' };
    local *Mediabot::Helpers::botPrivmsg = sub { push @{$_[0]{out}}, [$_[1],$_[2]]; 1 };
    {
        local $SIG{__WARN__} = sub { push @warnings, @_ };
        $error = eval {
            $handled = Mediabot::External::URL::displayUrlTitle($bot,undef,'Reader','#test',"$clean_url?si=offline");
            $before = [scalar @{$bot->{out}}, scalar @{$http->{calls}}];
            my $deadline = Time::HiRes::time()+8;
            $bot->{loop}->loop_once(.01) while keys(%{$bot->{_spotify_pending}//{}}) && Time::HiRes::time()<$deadline;
            1;
        } ? '' : "$@";
    }
    open my $read,'<:raw',$path or die $!;
    my @calls = map { JSON::PP::decode_json($_)->{url} } <$read>; close $read;
    my @out = map {
        my ($target,$line) = @$_;
        $line =~ s/\x03(?:\d{1,2}(?:,\d{1,2})?)?//g;
        $line =~ s/[\x02\x0f\x16\x1d\x1f]//g;
        [$target,$line];
    } @{$bot->{out}};
    is_deeply([$error,\@warnings,$handled,$before,\@out,\@calls,
              scalar keys %{$bot->{_spotify_pending}//{}}],
        ['',[],1,[0,0],[['#test',"(Reader) [Spotify] L'amour - by Guns N' Roses"]],$urls,0],
        'native dispatcher and actual AsyncWorker deliver one complete preview without parent HTTP and release pending ownership');
}
{
    is_deeply([
        metadata_1388(q{<meta property="og:title" content="Other song - Studio">}, {title=>'oEmbed title',artist=>'Known artist'}),
        metadata_1388(q{<meta property="og:title" content="Spotify"><meta name="twitter:title" content="Spotify Web Player"><title>Fallback song - Studio</title>}),
        metadata_1388(q{<meta property="og:title" content="Rock &amp; Roll - Studio"><meta property="og:description" content="Song - Studio - 2020">}),
        metadata_1388(q{<meta property="og:title" content="Good song - Studio"><meta property="og:title" content="">}),
    ],[
        expected_1388({title=>'oEmbed title',artist=>'Known artist'}),
        expected_1388({title=>'Fallback song',artist=>'Studio'}),
        expected_1388({title=>'Rock & Roll',artist=>'Studio',year=>'2020'}),
        expected_1388({title=>'Good song',artist=>'Studio'}),
    ],'existing preferred metadata, generic-shell rejection, title fallback and HTML entity cleanup remain intact');
}
done_testing;
