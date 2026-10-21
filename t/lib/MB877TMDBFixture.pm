package MB877TMDBFixture;
use strict;
use warnings;
use Exporter 'import';
use JSON::PP ();
use Mediabot::Mediabot;
use Mediabot::Context;
our @EXPORT_OK = qw(run_tmdb tmdb_movie);

{ package MB877TMDBFixture::Conf;
  sub get { return $_[0]{maxlen} if $_[1] eq 'main.MAIN_PROG_MAXLEN';
      return 'OFFLINE_FIXTURE_ONLY' if $_[1] eq 'tmdb.API_KEY'; return undef } }
{ package MB877TMDBFixture::Log; sub log {push @{$_[0]{lines}}, $_[2]; 1} }
{ package MB877TMDBFixture::HTTP;
  sub get {
      my ($self, $url) = @_;
      push @{$self->{calls}}, $url;
      die 'unexpected offline TMDB endpoint' unless $url =~ m{\Ahttps://api[.]themoviedb[.]org/3/search/multi\?};
      return $self->{response};
  } }

sub tmdb_movie {
    return {media_type => 'movie', title => 'Fixture movie', overview => 'A complete synopsis.',
        release_date => '2026-10-21', vote_average => 7.26};
}
sub run_tmdb {
    my ($doc, %args) = @_;
    my $bot = {conf => bless({maxlen => $args{maxlen} // 400}, 'MB877TMDBFixture::Conf'),
        logger => bless({lines => []}, 'MB877TMDBFixture::Log'), out => [], notices => []};
    my $http = bless({calls => [], response => $args{response} // {
        success => 1, status => 200, content => JSON::PP::encode_json($doc),
    }}, 'MB877TMDBFixture::HTTP');
    my $ctx = Mediabot::Context->new(bot => $bot, nick => $args{nick} // 'Reader',
        channel => '#test', command => 'tmdb', args => $args{args} // ['Fixture movie']);
    my (@options, @warnings, $result, $ok, $error);
    {
        no warnings qw(redefine once);
        local *Mediabot::External::_make_http = sub {push @options, {@_}; $http};
        local *Mediabot::External::getTMDBLangChannel = sub {'fr-FR'};
        local *Mediabot::Helpers::botPrivmsg = sub {push @{$_[0]{out}}, [$_[1], $_[2]]; 1};
        local *Mediabot::Helpers::botNotice = sub {push @{$_[0]{notices}}, [$_[1], $_[2]]; 1};
        local $SIG{__WARN__} = sub {push @warnings, @_};
        my %handlers = Mediabot::_builtin_public_command_handlers();
        my $handler = $args{handler} // $handlers{tmdb};
        $ok = eval {$result = $handler->($ctx); 1};
        $error = $@;
    }
    return {ok => $ok, error => $error, result => $result, bot => $bot,
        calls => $http->{calls}, options => \@options, warnings => \@warnings};
}
1;
